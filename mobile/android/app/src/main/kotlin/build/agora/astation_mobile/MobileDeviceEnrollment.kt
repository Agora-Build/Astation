package build.agora.astation_mobile

import android.util.Base64
import com.google.crypto.tink.subtle.X25519
import java.math.BigInteger
import java.net.URI
import java.security.AlgorithmParameters
import java.security.KeyFactory
import java.security.MessageDigest
import java.security.SecureRandom
import java.security.Signature
import java.security.spec.ECGenParameterSpec
import java.security.spec.ECParameterSpec
import java.security.spec.ECPoint
import java.security.spec.ECPublicKeySpec
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec
import org.json.JSONArray
import org.json.JSONObject
import uniffi.atem_client_ffi.AccountKey
import uniffi.atem_client_ffi.HostClock
import uniffi.atem_client_ffi.MembershipLog
import uniffi.atem_client_ffi.MemberStatusKind
import uniffi.atem_client_ffi.canonicalJson
import uniffi.atem_client_ffi.encodeFields
import uniffi.atem_client_ffi.hashFields
import uniffi.atem_client_ffi.signedObjectInfo

/** Native-only QR trust anchor. An account token or browser URL is not a trusted scan. */
internal class MobileEnrollmentInvitation private constructor(private val wire: String) {
    fun value() = JSONObject(wire)
    fun json() = wire
    val commitment get() = MobileDeviceEnrollment.digest("astation-device-invitation-v1", wire)

    companion object {
        fun scanned(text: String, issuer: String, owner: String, station: String, now: Long): MobileEnrollmentInvitation {
            val value = MobileDeviceEnrollment.read(text, setOf("version", "issuer", "owner", "station", "account", "genesis",
                "manager", "seq", "head", "id", "created", "expires", "roles", "secret"))
            val result = MobileEnrollmentInvitation(canonicalJson(value.toString()))
            result.validate(issuer, owner, station, now)
            return result
        }
    }

    fun validate(issuer: String, owner: String, station: String, now: Long) {
        val v = value()
        fun origin(name: String) {
            val raw = v.getString(name)
            val uri = URI(raw)
            val host = uri.host ?: ""
            require(uri.scheme == "https" && host.contains('.') && host == host.lowercase(java.util.Locale.ROOT) &&
                !host.endsWith('.') && !host.contains(':') && !host.all { it.isDigit() || it == '.' } &&
                (uri.port == -1 || (uri.port in 1..65535 && uri.port != 443)) && uri.rawPath == "" && uri.rawQuery == null &&
                uri.rawFragment == null && uri.rawUserInfo == null && uri.toASCIIString() == raw)
        }
        origin("issuer"); origin("station")
        require(v.getString("issuer") == issuer && v.getString("owner") == owner && v.getString("station") == station)
        for (name in listOf("owner", "account", "manager")) require(MobileDeviceEnrollment.id(v.getString(name)))
        require(v.getString("manager") != "recovery")
        for (name in listOf("genesis", "head")) require(MobileDeviceEnrollment.hash(v.getString(name)))
        require(MobileDeviceEnrollment.number(v, "version") == 1L && MobileDeviceEnrollment.number(v, "seq") in 1..8192)
        val created = MobileDeviceEnrollment.number(v, "created")
        val expires = MobileDeviceEnrollment.number(v, "expires")
        require(created < expires && expires - created <= 600_000 && now in created until expires)
        val roles = MobileDeviceEnrollment.strings(v.getJSONArray("roles"))
        require(roles == listOf("view") || roles == listOf("control", "view"))
        MobileDeviceEnrollment.bytes(v.getString("id"), 32)
        MobileDeviceEnrollment.bytes(v.getString("secret"), 32)
    }
}

/** Matches the Apple application ceremony; the Atem membership wire is unchanged. */
internal object MobileDeviceEnrollment {
    fun id(value: String) = Regex("[A-Za-z0-9._:-]{1,128}").matches(value)
    fun hash(value: String) = Regex("[0-9a-f]{64}").matches(value)
    fun text(value: ByteArray): String = Base64.encodeToString(value, Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING)
    fun bytes(value: String, count: Int): ByteArray = Base64.decode(value, Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING).also {
        require(it.size == count && text(it) == value)
    }
    fun read(text: String, fields: Set<String>, nullableObjects: Set<String> = emptySet()): JSONObject {
        require(text.toByteArray(Charsets.UTF_8).size <= 16_384)
        return JSONObject(canonicalJson(text)).also { value ->
            require(value.keys().asSequence().toSet() == fields)
            val otherTypes = setOf("version", "seq", "created", "expires", "body", "context", "roles", "keys")
            require(fields.containsAll(nullableObjects))
            for (field in nullableObjects) require(value.isNull(field) || value.get(field) is JSONObject)
            for (field in fields - otherTypes - nullableObjects) require(value.get(field) is String)
        }
    }
    fun number(value: JSONObject, name: String): Long {
        val number = value.get(name)
        require(number is Number && number.toDouble() >= 0 && number.toDouble() <= 9_007_199_254_740_991 &&
            number.toDouble() == number.toLong().toDouble())
        return number.toLong()
    }
    fun strings(value: JSONArray): List<String> = (0 until value.length()).map {
        require(value.get(it) is String); value.getString(it)
    }
    private fun utf8(value: String) = value.toByteArray(Charsets.UTF_8)
    private fun fields(vararg values: String) = encodeFields(values.map(::utf8))
    fun digest(domain: String, wire: String) = hashFields(listOf(utf8(domain), utf8(wire)))
    private fun mac(input: ByteArray, invitation: MobileEnrollmentInvitation): ByteArray = Mac.getInstance("HmacSHA256").run {
        init(SecretKeySpec(bytes(invitation.value().getString("secret"), 32), "HmacSHA256")); doFinal(input)
    }
    private fun verifyMAC(value: String, input: ByteArray, invitation: MobileEnrollmentInvitation) {
        require(MessageDigest.isEqual(bytes(value, 32), mac(input, invitation)))
    }

    fun request(invitation: MobileEnrollmentInvitation, device: String, auth: ByteArray, encryption: ByteArray,
        name: String, now: Long, sign: (ByteArray) -> ByteArray): String {
        val body = JSONObject().put("version", 1).put("invitation", invitation.commitment).put("device", device).put("name", name)
            .put("auth", text(auth)).put("encryption", text(encryption)).put("roles", invitation.value().getJSONArray("roles"))
            .put("nonce", text(ByteArray(32).also { SecureRandom().nextBytes(it) }))
        val signature = sign(fields("astation-device-applicant-proof-v1", canonicalJson(body.toString())))
        val input = encodeFields(listOf(utf8("astation-device-request-auth-v1"), utf8(canonicalJson(body.toString())), signature))
        val request = canonicalJson(JSONObject().put("body", body).put("signature", text(signature)).put("mac", text(mac(input, invitation))).toString())
        validateRequest(request, invitation, now)
        return request
    }

    fun validateRequest(wire: String, invitation: MobileEnrollmentInvitation, now: Long): JSONObject {
        val inv = invitation.value()
        invitation.validate(inv.getString("issuer"), inv.getString("owner"), inv.getString("station"), now)
        val request = read(wire, setOf("body", "signature", "mac"))
        val body = read(request.getJSONObject("body").toString(), setOf("version", "invitation", "device", "name", "auth", "encryption", "roles", "nonce"))
        require(number(body, "version") == 1L && body.getString("invitation") == invitation.commitment &&
            id(body.getString("device")) && body.getString("device") !in listOf("recovery", inv.getString("manager")) &&
            strings(body.getJSONArray("roles")) == strings(inv.getJSONArray("roles")))
        val name = body.getString("name")
        require(utf8(name).size in 1..80 && name == name.trim() && name.none {
            Character.getType(it) == Character.CONTROL.toInt() || Character.getType(it) == Character.FORMAT.toInt()
        })
        bytes(body.getString("nonce"), 32)
        val auth = bytes(body.getString("auth"), 65)
        require(auth[0] == 4.toByte())
        X25519.computeSharedSecret(ByteArray(32) { 7 }, bytes(body.getString("encryption"), 32))
        val signature = bytes(request.getString("signature"), 64)
        val canonical = canonicalJson(body.toString())
        verifyMAC(request.getString("mac"), encodeFields(listOf(utf8("astation-device-request-auth-v1"), utf8(canonical), signature)), invitation)
        verifyP256(auth, signature, fields("astation-device-applicant-proof-v1", canonical))
        return body
    }

    fun safetyCode(request: String): String = digest("astation-device-request-v1", canonicalJson(request))
        .take(12).uppercase(java.util.Locale.ROOT).chunked(4).joinToString("-")

    fun validateHandoff(handoff: String, invitation: MobileEnrollmentInvitation, request: String, now: Long): JSONObject {
        validateRequest(request, invitation, now)
        val inv = invitation.value()
        val envelope = read(handoff, setOf("context", "enc", "ciphertext", "mac"))
        val context = read(envelope.getJSONObject("context").toString(), setOf("version", "invitation", "request", "seq", "head", "entry"))
        require(number(context, "version") == 1L && context.getString("invitation") == invitation.commitment &&
            context.getString("request") == digest("astation-device-request-v1", canonicalJson(request)))
        require(number(context, "seq") > number(inv, "seq") && number(context, "seq") <= 8192 && hash(context.getString("head")) && hash(context.getString("entry")))
        bytes(envelope.getString("enc"), 32)
        val ciphertext = envelope.getString("ciphertext")
        require(ciphertext.length <= 12_000)
        val decoded = Base64.decode(ciphertext, Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING)
        require(decoded.size in 16..9000 && text(decoded) == ciphertext)
        verifyMAC(envelope.getString("mac"), encodeFields(listOf(utf8("astation-device-handoff-auth-v1"), utf8(canonicalJson(context.toString())),
            utf8(envelope.getString("enc")), utf8(ciphertext))), invitation)
        return envelope
    }

    /** Returns only after exact recipient/log validation, decryption and the caller's atomic protected save. */
    fun accept(handoff: String, invitation: MobileEnrollmentInvitation, request: String, device: String,
        auth: ByteArray, encryption: ByteArray, log: MembershipLog, now: HostClock,
        open: (ByteArray, ByteArray, ByteArray, ByteArray) -> ByteArray, persist: (ByteArray) -> Unit): List<AccountKey> {
        val body = validateRequest(request, invitation, now.wallMs.toLong())
        val inv = invitation.value()
        require(body.getString("device") == device && body.getString("auth") == text(auth) && body.getString("encryption") == text(encryption))
        val envelope = validateHandoff(handoff, invitation, request, now.wallMs.toLong())
        val context = envelope.getJSONObject("context")
        val sequence = number(context, "seq")
        val aad = utf8(canonicalJson(context.toString()))
        log.snapshot().use { current ->
            current.advance(now)
            val entries = current.entries()
            require(current.accountId() == inv.getString("account") && current.genesisHash() == inv.getString("genesis") && current.frozen() == null &&
                entries.size >= sequence && signedObjectInfo(entries[number(inv, "seq").toInt() - 1]).entryHash == inv.getString("head") &&
                signedObjectInfo(entries[sequence.toInt() - 1]).entryHash == context.getString("head"))
            val manager = current.member(inv.getString("manager"))
            require(manager?.kind == "native" && manager.status == MemberStatusKind.ACTIVE && "manage" in manager.roles)
            val member = current.member(device)
            require(member?.kind == "native" && member.status == MemberStatusKind.ACTIVE && member.roles == strings(body.getJSONArray("roles")) &&
                member.authKey.alg == uniffi.atem_client_ffi.KeyAlg.P256 && member.authKey.raw.contentEquals(auth) &&
                member.encKey?.alg == uniffi.atem_client_ffi.KeyAlg.X25519 && member.encKey?.raw?.contentEquals(encryption) == true)
            require(entries.drop(number(inv, "seq").toInt()).any { entry ->
                val info = signedObjectInfo(entry)
                val signed = JSONObject(info.bodyJcs)
                info.entryHash == context.getString("entry") && signed.optString("action") == "add" &&
                    signed.optString("signer") == inv.getString("manager") &&
                    number(signed, "signed_at") in number(inv, "created") until number(inv, "expires") &&
                    canonicalJson(signed.getJSONObject("member").toString()) == canonicalJson(member.memberJson)
            })
            val ciphertextText = envelope.getString("ciphertext")
            require(ciphertextText.length <= 12_000)
            val ciphertext = Base64.decode(ciphertextText, Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING)
            require(ciphertext.size in 16..9000 && text(ciphertext) == ciphertextText)
            val plaintext = open(bytes(envelope.getString("enc"), 32), ciphertext,
                fields("astation-device-handoff-hpke-v1", context.getString("invitation"), context.getString("request")), aad)
            try {
                val payload = read(MobileTokenValidator.utf8(plaintext), setOf("keys"))
                val keys = payload.getJSONArray("keys")
                require(keys.length() in 1..32)
                val result = (0 until keys.length()).map { index ->
                    val key = read(keys.getJSONObject(index).toString(), setOf("kid", "k"))
                    require(id(key.getString("kid")))
                    AccountKey(key.getString("kid"), bytes(key.getString("k"), 32))
                }
                require(result.map { it.kid }.toSet().size == result.size)
                val checkpoint = JSONObject().put("version", 1).put("issuer", inv.getString("issuer")).put("owner", inv.getString("owner"))
                    .put("station", inv.getString("station")).put("account", inv.getString("account")).put("genesis", inv.getString("genesis"))
                    .put("device", device).put("auth", body.getString("auth")).put("encryption", body.getString("encryption"))
                    .put("membership", current.storedJson()).put("keys", keys)
                persist(utf8(canonicalJson(checkpoint.toString())))
                return result
            } finally { plaintext.fill(0) }
        }
    }

    private fun verifyP256(publicKey: ByteArray, raw: ByteArray, input: ByteArray) {
        fun integer(value: ByteArray): ByteArray {
            val positive = BigInteger(1, value).toByteArray()
            return byteArrayOf(2, positive.size.toByte()) + positive
        }
        val values = integer(raw.copyOfRange(0, 32)) + integer(raw.copyOfRange(32, 64))
        val der = byteArrayOf(0x30, values.size.toByte()) + values
        require(MobileP256Signature.fromDER(der).contentEquals(raw))
        val params = AlgorithmParameters.getInstance("EC").apply { init(ECGenParameterSpec("secp256r1")) }.getParameterSpec(ECParameterSpec::class.java)
        val key = KeyFactory.getInstance("EC").generatePublic(ECPublicKeySpec(ECPoint(BigInteger(1, publicKey.copyOfRange(1, 33)),
            BigInteger(1, publicKey.copyOfRange(33, 65))), params))
        require(Signature.getInstance("SHA256withECDSA").run { initVerify(key); update(input); verify(der) })
    }
}
