package build.agora.astation_mobile

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.security.KeyStore
import java.util.UUID
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import uniffi.atem_client_ffi.HostClock
import uniffi.atem_client_ffi.MembershipLog
import uniffi.atem_client_ffi.canonicalJson
import uniffi.atem_client_ffi.hashFields
import uniffi.atem_client_ffi.uniffiEnsureInitialized

@RunWith(AndroidJUnit4::class)
class MobileDeviceEnrollmentTest {
    private val context: Context = ApplicationProvider.getApplicationContext()
    private val testOwner = "enrollment-test-" + UUID.randomUUID()
    private var identity: MobileDeviceIdentity? = null
    private lateinit var vector: JSONObject
    private lateinit var invitation: MobileEnrollmentInvitation
    private lateinit var clock: HostClock

    @Before fun setUp() {
        uniffiEnsureInitialized()
        val assets = InstrumentationRegistry.getInstrumentation().context.assets
        vector = JSONObject(assets.open("native-device-enrollment-v1.json").bufferedReader().use { it.readText() })
        val inv = JSONObject(vector.getString("invitation"))
        clock = HostClock(vector.getLong("wall").toULong(), 100u, "enrollment-android-test")
        invitation = MobileEnrollmentInvitation.scanned(inv.toString(), inv.getString("issuer"), inv.getString("owner"), inv.getString("station"), clock.wallMs.toLong())
    }

    @After fun removeOnlySyntheticIdentity() {
        identity?.close()
        if (::invitation.isInitialized) {
            val scope = hashFields(listOf("astation-native-device-identity-v1", invitation.value().getString("issuer"), testOwner).map { it.toByteArray() })
            val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
            for (kind in listOf("auth", "wrap")) store.deleteEntry("build.agora.astation.device.$kind.$scope")
            File(context.noBackupFilesDir, "device-identities-v1").listFiles()?.filter { it.name.startsWith(scope + ".") }?.forEach { it.delete() }
        }
    }

    private fun log(entries: List<String> = MobileDeviceEnrollment.strings(vector.getJSONArray("entries"))): MembershipLog =
        MembershipLog.verify(invitation.value().getString("account"), invitation.value().getString("genesis"), entries, clock)

    private fun accept(handoff: String = vector.getString("handoff"), log: MembershipLog,
        persist: (ByteArray) -> Unit): List<uniffi.atem_client_ffi.AccountKey> {
        val request = vector.getString("request")
        val body = MobileDeviceEnrollment.validateRequest(request, invitation, clock.wallMs.toLong())
        return MobileDeviceEnrollment.accept(handoff, invitation, request, body.getString("device"),
            MobileDeviceEnrollment.bytes(body.getString("auth"), 65), MobileDeviceEnrollment.bytes(body.getString("encryption"), 32), log, clock,
            { enc, ct, info, aad -> MobileHpke.open(MobileDeviceEnrollment.bytes(vector.getString("recipient_private"), 32), enc, ct, info, aad) }, persist)
    }

    @Test fun appleRequestAndSealedKeyHandoffAreVerifiedByAndroid() {
        assertEquals(vector.getString("safety_code"), MobileDeviceEnrollment.safetyCode(vector.getString("request")))
        var saved: ByteArray? = null
        log().use { log ->
            val keys = accept(log = log) { saved = it }
            assertEquals(1, keys.size)
            assertArrayEquals(MobileDeviceEnrollment.bytes(vector.getString("account_key"), 32), keys[0].k)
            val checkpoint = JSONObject(String(saved!!, Charsets.UTF_8))
            assertEquals(invitation.value().getString("genesis"), checkpoint.getString("genesis"))
            assertEquals(log.storedJson(), checkpoint.getString("membership"))
            assertThrows(Exception::class.java) { accept(log = log) { throw MobileDeviceIdentityFailure("storage") } }
        }
    }

    @Test fun nativeMailboxRoundTripCarriesOnlyPublicProofAndSealedKeys() = runBlocking {
        val inv = invitation.value()
        var request: JSONObject? = null
        var response: JSONObject? = null
        val methods = mutableListOf<String>()
        val transport = MobileDeviceEnrollmentHTTP(inv.getString("station")) { method, path, body ->
            methods.add(method)
            assertEquals("/api/remote/v1/logs/${inv.getString("genesis")}/device-enrollments/${inv.getString("id")}", path)
            assertFalse(body?.toString()?.contains(inv.getString("secret")) ?: false)
            when (method) {
                "PUT" -> assertEquals(setOf("expires"), body!!.keys().asSequence().toSet())
                "POST" -> when (body!!.getString("stage")) {
                    "request" -> request = body.getJSONObject("message")
                    "response" -> response = body.getJSONObject("message")
                    else -> fail("Unknown stage")
                }
                "GET" -> assertNull(body)
                "DELETE" -> return@MobileDeviceEnrollmentHTTP 200 to JSONObject().put("closed", true)
                else -> fail("Unknown method")
            }
            200 to JSONObject().put("expires", inv.getLong("expires"))
                .put("request", request ?: JSONObject.NULL).put("response", response ?: JSONObject.NULL)
        }
        val now = clock.wallMs.toLong()
        assertNull(transport.create(invitation, now).request)
        val original = vector.getString("request")
        assertEquals(canonicalJson(original), transport.submit(original, invitation, now).request)
        assertEquals(canonicalJson(original), transport.read(invitation, now).request)
        val handoff = vector.getString("handoff")
        assertEquals(canonicalJson(handoff), transport.publish(handoff, original, invitation, now).response)
        assertEquals(canonicalJson(handoff), transport.read(invitation, now).response)
        transport.cancel(invitation)
        assertEquals(listOf("PUT", "POST", "GET", "POST", "GET", "DELETE"), methods)
    }

    @Test fun mailboxRejectsWrongStationExtendedExpiryAndMalformedNestedMessages() = runBlocking {
        val inv = invitation.value()
        val now = clock.wallMs.toLong()
        suspend fun refused(block: suspend () -> Unit) {
            try { block(); fail("Unverified mailbox accepted") } catch (_: Exception) { }
        }
        val wrong = MobileDeviceEnrollmentHTTP("https://station.agora.build") { _, _, _ ->
            fail("Wrong Station must fail before requesting a token"); 500 to JSONObject()
        }
        refused { wrong.create(invitation, now) }
        for (change in 0..5) {
            val transport = MobileDeviceEnrollmentHTTP(inv.getString("station")) { _, _, _ ->
                val body = JSONObject().put("expires", inv.getLong("expires"))
                    .put("request", JSONObject.NULL).put("response", JSONObject.NULL)
                when (change) {
                    0 -> body.put("expires", inv.getLong("expires") + 1)
                    1 -> body.put("request", "not-an-object")
                    2 -> body.put("request", JSONObject(vector.getString("request")).also { it.getJSONObject("body").put("name", "Changed") })
                    3 -> body.put("response", JSONObject(vector.getString("handoff")))
                    4 -> body.put("ignored", true)
                    5 -> body.put("request", JSONObject(vector.getString("request"))).put("response",
                        JSONObject(vector.getString("handoff")).put("mac", MobileDeviceEnrollment.text(ByteArray(32))))
                }
                200 to body
            }
            refused { transport.read(invitation, now) }
        }
    }

    @Test fun mailboxRefusalsRemainDistinctAndCancelCanBeRetried() = runBlocking {
        for ((status, code, expected) in listOf(Triple(404, "device_enrollment_not_found", "not_found"),
            Triple(409, "device_enrollment_conflict", "conflict"), Triple(410, "device_enrollment_closed", "closed"),
            Triple(429, "device_enrollment_limit", "limit"), Triple(503, "unavailable", "unavailable"))) {
            val transport = MobileDeviceEnrollmentHTTP(invitation.value().getString("station")) { _, _, _ ->
                status to JSONObject().put("error", JSONObject().put("code", code))
            }
            try { transport.read(invitation, clock.wallMs.toLong()); fail("HTTP refusal") }
            catch (error: MobileEnrollmentTransportFailure) { assertEquals(expected, error.reason) }
            if (status == 410) transport.cancel(invitation)
        }
    }

    @Test fun foreignStationChangedKeysAndUncommittedMembershipCannotCompleteSetup() {
        val inv = invitation.value()
        assertThrows(Exception::class.java) {
            MobileEnrollmentInvitation.scanned(invitation.json(), inv.getString("issuer"), inv.getString("owner"),
                "https://station.agora.build", clock.wallMs.toLong())
        }
        val request = JSONObject(vector.getString("request"))
        request.getJSONObject("body").put("name", "Replaced phone")
        assertThrows(Exception::class.java) { MobileDeviceEnrollment.validateRequest(request.toString(), invitation, clock.wallMs.toLong()) }
        for (field in listOf("enc", "ciphertext", "mac")) {
            val altered = JSONObject(vector.getString("handoff")).put(field, MobileDeviceEnrollment.text(ByteArray(32) { 4 })).toString()
            log().use { log -> assertThrows(Exception::class.java) { accept(altered, log) { fail("Invalid handoff saved") } } }
        }
        log(MobileDeviceEnrollment.strings(vector.getJSONArray("entries")).take(1)).use { prefix ->
            assertThrows(Exception::class.java) { accept(log = prefix) { fail("Missing signed enrollment saved") } }
        }
    }

    @Test fun nativeEnrollmentProofRequiresFreshOwnerConsentAndPersistsBeforeExposure() = runBlocking {
        val inv = invitation.value().put("owner", testOwner)
        val scanned = MobileEnrollmentInvitation.scanned(inv.toString(), inv.getString("issuer"), testOwner, inv.getString("station"), clock.wallMs.toLong())
        val device = MobileDeviceIdentity.open(context, inv.getString("issuer"), testOwner).also { identity = it }
        var saved: String? = null
        try {
            device.enrollmentRequest(scanned, inv.getString("station"), "Android test", { clock.wallMs.toLong() }, { true }, { false }) { saved = it }
            fail("Owner denied")
        } catch (error: MobileDeviceIdentityFailure) { assertEquals("owner_denied", error.reason) }
        assertNull(saved)
        val request = device.enrollmentRequest(scanned, inv.getString("station"), "Android test", { clock.wallMs.toLong() }, { true }, { true }) { saved = it }
        assertEquals(saved, request)
        val body = MobileDeviceEnrollment.validateRequest(request, scanned, clock.wallMs.toLong())
        assertEquals(device.deviceId, body.getString("device"))
        var current = true
        try {
            device.enrollmentRequest(scanned, inv.getString("station"), "Android test", { clock.wallMs.toLong() }, { current },
                { current = false; true }) { fail("Changed account must not save") }
            fail("Account changed")
        } catch (error: MobileDeviceIdentityFailure) { assertEquals("context_changed", error.reason) }
    }

    @Test fun strictFormatsAndExactExpiryMatchTheAppleGate() {
        val inv = invitation.value()
        val expires = inv.getLong("expires")
        assertThrows(Exception::class.java) {
            MobileEnrollmentInvitation.scanned(invitation.json(), inv.getString("issuer"), inv.getString("owner"), inv.getString("station"), expires)
        }
        for (url in listOf("https://localhost", "https://127.0.0.1", "https://station-dev.agora.build:443", "https://station-dev.agora.build/")) {
            val changed = invitation.value().put("station", url)
            assertThrows(Exception::class.java) { MobileEnrollmentInvitation.scanned(changed.toString(), inv.getString("issuer"), inv.getString("owner"), url, clock.wallMs.toLong()) }
        }
        val extra = invitation.value().put("ignored", true)
        assertThrows(Exception::class.java) { MobileEnrollmentInvitation.scanned(extra.toString(), inv.getString("issuer"), inv.getString("owner"), inv.getString("station"), clock.wallMs.toLong()) }
        val stringNumber = invitation.value().put("seq", "1")
        assertThrows(Exception::class.java) { MobileEnrollmentInvitation.scanned(stringNumber.toString(), inv.getString("issuer"), inv.getString("owner"), inv.getString("station"), clock.wallMs.toLong()) }
    }
}
