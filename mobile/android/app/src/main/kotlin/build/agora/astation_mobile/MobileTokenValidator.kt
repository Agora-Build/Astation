package build.agora.astation_mobile

import org.json.JSONObject
import java.math.BigInteger
import java.security.AlgorithmParameters
import java.security.KeyFactory
import java.security.Signature
import java.security.spec.ECGenParameterSpec
import java.security.spec.ECParameterSpec
import java.security.spec.ECPoint
import java.security.spec.ECPublicKeySpec
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction

/** All signed claims are checked locally before any token reaches the selected Station. */
internal object MobileTokenValidator {
    fun utf8(bytes: ByteArray): String = Charsets.UTF_8.newDecoder()
        .onMalformedInput(CodingErrorAction.REPORT).onUnmappableCharacter(CodingErrorAction.REPORT)
        .decode(ByteBuffer.wrap(bytes)).toString()
    fun integer(value: JSONObject, name: String): Long {
        val raw = value.opt(name)
        if (raw !is Number || raw.toDouble() < 0 || raw.toDouble() > 9_007_199_254_740_991.0 ||
            !raw.toDouble().isFinite() || raw.toDouble() != raw.toLong().toDouble()) fail()
        return raw.toLong()
    }
    fun verify(jwt: String, jwks: JSONObject, config: MobileOAuthConfig, id: Boolean, now: Long,
               canonical: (String) -> String): JSONObject {
        try {
            if (jwt.length > 16384) fail()
            val parts = jwt.split('.')
            if (parts.size != 3) fail()
            val header = JSONObject(canonical(utf8(decode(parts[0]))))
            val claims = JSONObject(canonical(utf8(decode(parts[1]))))
            if (header.optString("alg") != "ES256" || header.has("crit") ||
                (!id && header.optString("typ") != "at+jwt") ||
                (id && header.has("typ") && header.optString("typ") != "JWT")) fail()
            val kid = header.getString("kid")
            if (kid.isEmpty() || kid.length > 128) fail()
            val entries = jwks.getJSONArray("keys")
            if (entries.length() !in 1..64) fail()
            var selected: JSONObject? = null
            val ids = mutableSetOf<String>()
            for (index in 0 until entries.length()) {
                val key = entries.getJSONObject(index)
                if (key.optString("kty") != "EC" || key.optString("crv") != "P-256" ||
                    (key.has("alg") && key.optString("alg") != "ES256") ||
                    (key.has("use") && key.optString("use") != "sig")) continue
                if (key.has("key_ops")) {
                    val ops = key.getJSONArray("key_ops")
                    if ((0 until ops.length()).none { ops.getString(it) == "verify" }) continue
                }
                val keyId = key.getString("kid")
                if (keyId.isEmpty() || keyId.length > 128 || !ids.add(keyId)) fail()
                if (keyId == kid) selected = key
            }
            val key = selected ?: fail()
            val x = decode(key.getString("x")); val y = decode(key.getString("y"))
            if (x.size != 32 || y.size != 32) fail()
            val params = AlgorithmParameters.getInstance("EC").apply { init(ECGenParameterSpec("secp256r1")) }
                .getParameterSpec(ECParameterSpec::class.java)
            val publicKey = KeyFactory.getInstance("EC").generatePublic(ECPublicKeySpec(ECPoint(BigInteger(1, x), BigInteger(1, y)), params))
            val raw = decode(parts[2])
            if (raw.size != 64) fail()
            fun derInt(bytes: ByteArray): ByteArray {
                var first = 0
                while (first < bytes.lastIndex && bytes[first] == 0.toByte()) first++
                val positive = bytes.copyOfRange(first, bytes.size).let { if (it[0] < 0) byteArrayOf(0) + it else it }
                return byteArrayOf(2, positive.size.toByte()) + positive
            }
            val integers = derInt(raw.copyOfRange(0, 32)) + derInt(raw.copyOfRange(32, 64))
            val valid = Signature.getInstance("SHA256withECDSA").run {
                initVerify(publicKey); update((parts[0] + "." + parts[1]).toByteArray(Charsets.US_ASCII))
                verify(byteArrayOf(0x30, integers.size.toByte()) + integers)
            }
            if (!valid) fail()
            val audience = claims.opt("aud")
            val audiences = if (audience is String) listOf(audience) else {
                val array = claims.getJSONArray("aud")
                (0 until array.length()).map { array.getString(it) }
            }
            if (claims.getString("iss") != config.issuer ||
                (if (id) config.clientId else config.station) !in audiences ||
                (id && (audiences.size > 1 || claims.has("azp")) && claims.optString("azp") != config.clientId)) fail()
            val subject = claims.getString("sub")
            if (!Regex("ab[0-9A-HJKMNP-TV-Z]{26}").matches(subject)) fail()
            val iat = integer(claims, "iat"); val exp = integer(claims, "exp")
            if (exp <= now || iat > now + 30 || exp <= iat || exp - iat > if (id) 3600 else 900) fail()
            if (claims.has("nbf") && integer(claims, "nbf") > now) fail()
            if (integer(claims, "auth_time") > iat + 30) fail()
            if (!id && (claims.getString("client_id") != config.clientId ||
                "astation.remote" !in claims.getString("scope").split(' '))) fail()
            return claims
        } catch (e: MobileLoginFailure) { throw e }
        catch (_: Exception) { fail() }
    }

    private fun decode(text: String): ByteArray {
        val alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
        if (text.length % 4 == 1) fail()
        var bits = 0; var count = 0
        val output = ArrayList<Byte>()
        for (char in text) {
            val digit = alphabet.indexOf(char)
            if (digit < 0) fail()
            bits = (bits shl 6) or digit; count += 6
            if (count >= 8) { count -= 8; output.add((bits shr count).toByte()) }
        }
        if (count > 0 && bits and ((1 shl count) - 1) != 0) fail()
        return output.toByteArray()
    }
    private fun fail(): Nothing = throw MobileLoginFailure("invalid_response")
}
