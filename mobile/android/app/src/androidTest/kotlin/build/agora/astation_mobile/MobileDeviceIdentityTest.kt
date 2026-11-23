package build.agora.astation_mobile

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.google.crypto.tink.subtle.X25519
import com.google.crypto.tink.subtle.Ed25519Sign
import java.io.File
import java.security.KeyStore
import java.security.PrivateKey
import java.security.Signature
import java.util.UUID
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.json.JSONObject
import uniffi.atem_client_ffi.HostClock
import uniffi.atem_client_ffi.MembershipLog
import uniffi.atem_client_ffi.KeyAlg
import uniffi.atem_client_ffi.PublicKeyData
import uniffi.atem_client_ffi.SignLabelKind
import uniffi.atem_client_ffi.SignRequest
import uniffi.atem_client_ffi.SigningPurpose
import uniffi.atem_client_ffi.hashFields
import uniffi.atem_client_ffi.signingInput
import uniffi.atem_client_ffi.uniffiEnsureInitialized
import uniffi.atem_client_ffi.verifySignature
import uniffi.atem_client_ffi.signedObjectInfo
import uniffi.atem_client_ffi.verifierInventory
import uniffi.atem_client_ffi.verifierReportChallenge
import uniffi.atem_client_ffi.verifierReportProcess
import uniffi.atem_client_ffi.verifyVerifierReport

@RunWith(AndroidJUnit4::class)
class MobileDeviceIdentityTest {
    private val context: Context = ApplicationProvider.getApplicationContext()
    private val issuer = "https://auth.dev.agora.build"
    private val account = "identity-test-" + UUID.randomUUID()
    private lateinit var scope: String
    private val identities = mutableListOf<MobileDeviceIdentity>()

    @Before fun setUp() {
        uniffiEnsureInitialized()
        scope = hashFields(listOf("astation-native-device-identity-v1", issuer, account).map { it.toByteArray() })
    }

    @After fun removeOnlyThisTestsKeys() {
        identities.forEach { it.close() }
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        for (kind in listOf("auth", "wrap")) store.deleteEntry("build.agora.astation.device.$kind.$scope")
        File(context.noBackupFilesDir, "device-identities-v1").listFiles()?.filter { it.name.startsWith(scope + ".") }?.forEach { it.delete() }
    }

    private fun open(existingOnly: Boolean = false): MobileDeviceIdentity =
        MobileDeviceIdentity.open(context, issuer, account, existingOnly).also { identities += it }
    private fun request(identity: MobileDeviceIdentity) = SignRequest(identity.deviceId, SigningPurpose.CHANNEL, false,
        "atem-ch1-client-sig-v1", signingInput(SignLabelKind.CHANNEL_CLIENT, ByteArray(32) { 7 }), null)

    private fun reportLog(identity: MobileDeviceIdentity, owner: String = "protocol-account"): MembershipLog {
        val body = JSONObject().put("type", "atem-membership-entry").put("v", 1).put("account_id", owner)
            .put("seq", 1).put("prev_hash", "0".repeat(64)).put("action", "genesis")
            .put("signer", identity.deviceId).put("signed_at", 1_792_400_000_000L)
            .put("member", JSONObject().put("device_id", identity.deviceId).put("kind", "native")
                .put("roles", org.json.JSONArray(listOf("control", "manage", "view")))
                .put("auth_key", JSONObject().put("alg", "p256").put("pub", MobileDeviceEnrollment.text(identity.authPublicKey)))
                .put("enc_key", JSONObject().put("alg", "x25519").put("pub", MobileDeviceEnrollment.text(identity.encryptionPublicKey))))
            .put("recovery_key", JSONObject().put("alg", "ed25519")
                .put("pub", MobileDeviceEnrollment.text(Ed25519Sign.KeyPair.newKeyPair().publicKey)))
        val objectJSON = JSONObject().put("body", body).put("sig", MobileDeviceEnrollment.text(ByteArray(64)))
        val input = signedObjectInfo(objectJSON.toString()).signingInput
        val key = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
            .getKey("build.agora.astation.device.auth.$scope", null) as PrivateKey
        val signature = Signature.getInstance("SHA256withECDSA").run { initSign(key); update(input); sign() }
        objectJSON.put("sig", MobileDeviceEnrollment.text(MobileP256Signature.fromDER(signature)))
        val entry = objectJSON.toString()
        return MembershipLog.verify(owner, signedObjectInfo(entry).entryHash!!, listOf(entry),
            HostClock(1_792_400_000_000uL, 100uL, "android-report-tests"))
    }

    @Test fun reportingLoadNeverCreatesKeysAndRestoresOnlyTheExistingIdentity() {
        val failure = assertThrows(MobileDeviceIdentityFailure::class.java) { open(existingOnly = true) }
        assertEquals("missing_identity", failure.reason)
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        for (kind in listOf("auth", "wrap")) assertFalse(store.containsAlias("build.agora.astation.device.$kind.$scope"))
        val first = open()
        val id = first.deviceId
        val file = File(context.noBackupFilesDir, "device-identities-v1/$scope.bin")
        val saved = file.readBytes()
        first.close()
        val restored = open(existingOnly = true)
        assertEquals(id, restored.deviceId)
        assertArrayEquals(saved, file.readBytes())
        restored.close()
        file.writeBytes(byteArrayOf(0))
        assertThrows(Exception::class.java) { open(existingOnly = true) }
        assertArrayEquals(byteArrayOf(0), file.readBytes())
    }

    @Test fun verifierReportUsesTheLoadedCoreAndExistingKeystoreKeyWithoutOwnerPrompts() {
        val identity = open()
        val file = File(context.noBackupFilesDir, "device-identities-v1/$scope.bin")
        val saved = file.readBytes()
        val wall = 1_792_400_000_000uL
        val challenge = verifierReportChallenge("member:${identity.deviceId}", "astation-android", "https://station.example",
            1uL, wall, wall + 30_000uL)
        reportLog(identity).use { log ->
            val anchor = MobileVerifierReportAnchor(log)
            fun report(station: String = "https://station.example", current: Boolean = true): String =
                identity.verifierReport(log, anchor, challenge, "astation-android", station, wall) { current }
            val verified = verifyVerifierReport(log, report(), challenge, wall)
            assertEquals(verifierReportProcess(), verified.process)
            assertEquals(verifierInventory(), verified.inventory)
            assertTrue(verified.atHead)
            assertArrayEquals(saved, file.readBytes())
            assertThrows(Exception::class.java) { report(station = "https://other.example") }
            assertThrows(Exception::class.java) { report(current = false) }
            reportLog(identity, owner = "another-account").use { other ->
                assertThrows(Exception::class.java) {
                    identity.verifierReport(other, anchor, challenge, "astation-android", "https://station.example", wall) { true }
                }
            }
            file.writeBytes(byteArrayOf(0))
            assertThrows(Exception::class.java) { report() }
            file.writeBytes(saved)
            assertThrows(Exception::class.java) { report() } // Uncertain storage requires reload.
        }
    }

    @Test fun keystoreIdentitySurvivesReloadAndItsPrivateSigningKeyCannotBeExported() {
        val first = open()
        val id = first.deviceId
        val auth = first.authPublicKey
        val encryption = first.encryptionPublicKey
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        assertNull(store.getKey("build.agora.astation.device.auth.$scope", null).encoded)
        assertNull(store.getKey("build.agora.astation.device.wrap.$scope", null).encoded)
        assertThrows(Exception::class.java) { MobileDeviceIdentity.open(context, issuer, account) }
        first.close()
        val restored = open()
        assertEquals(id, restored.deviceId)
        assertArrayEquals(auth, restored.authPublicKey)
        assertArrayEquals(encryption, restored.encryptionPublicKey)
        restored.authPublicKey.fill(0)
        assertArrayEquals(auth, restored.authPublicKey)
        val peer = X25519.generatePrivateKey()
        assertArrayEquals(X25519.computeSharedSecret(peer, encryption), restored.sharedSecret(X25519.publicFromPrivate(peer)))
        assertThrows(Exception::class.java) { restored.sharedSecret(ByteArray(32)) }
    }

    @Test fun channelSignatureRequiresOwnerApprovalAndSDKTranscriptValidation() = runBlocking {
        val identity = open()
        var foreground = true
        var allowed = false
        var prompts = 0
        var time = 100L
        val signer = identity.channelSigner({ time }, { foreground }, { prompts++; allowed })
        val request = request(identity)
        try { signer.sign(request) { true }; fail("Owner denied") } catch (_: MobileDeviceIdentityFailure) { }
        allowed = true
        val signature = signer.sign(request) { true }
        verifySignature(PublicKeyData(KeyAlg.P256, identity.authPublicKey), SignLabelKind.CHANNEL_CLIENT, ByteArray(32) { 7 }, signature)
        assertEquals(2, prompts)
        signer.sign(request) { true }
        assertEquals(2, prompts)
        time += 300_000
        signer.sign(request) { true }
        assertEquals(3, prompts)
        foreground = false
        try { signer.sign(request) { true }; fail("Background") } catch (_: MobileDeviceIdentityFailure) { }
        foreground = true
        signer.sign(request) { true }
        assertEquals(4, prompts)
        try { signer.sign(request.copy(purpose = SigningPurpose.ENROLL)) { true }; fail("Wrong purpose") }
        catch (_: MobileDeviceIdentityFailure) { }
    }

    @Test fun invalidatedOwnerPromptCannotRestoreSigningAuthority() = runBlocking {
        val identity = open()
        lateinit var signer: MobileDeviceChannelSigner
        signer = identity.channelSigner({ 100L }, { true }, { signer.invalidate(); true })
        try { signer.sign(request(identity)) { true }; fail("Invalidated confirmation") }
        catch (error: MobileDeviceIdentityFailure) { assertEquals("context_changed", error.reason) }
    }

    @Test fun corruptOrMissingSavedRecordNeverReplacesExistingKeystoreKeys() {
        val identity = open()
        val auth = identity.authPublicKey
        val file = File(context.noBackupFilesDir, "device-identities-v1/$scope.bin")
        val original = file.readBytes()
        file.writeBytes(original.copyOf().also { it[15] = (it[15].toInt() xor 1).toByte() })
        assertThrows(Exception::class.java) { identity.sharedSecret(ByteArray(32) { 3 }) }
        identity.close()
        assertThrows(Exception::class.java) { open() }
        file.writeBytes(original)
        val restored = open()
        assertArrayEquals(auth, restored.authPublicKey)
        restored.close()
        assertTrue(file.delete())
        val failure = assertThrows(MobileDeviceIdentityFailure::class.java) { open() }
        assertEquals("incomplete_setup", failure.reason)
    }
}
