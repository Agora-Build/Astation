package build.agora.astation_mobile

import org.json.JSONObject
import org.json.JSONArray
import org.junit.Assert.*
import org.junit.Test
import java.security.KeyPairGenerator
import java.security.Signature
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec
import java.util.Base64

class MobileTokenValidatorTest {
    private val config = MobileOAuthConfig(true)
    private val now = 1_800_000_000L
    private val key = KeyPairGenerator.getInstance("EC").apply { initialize(ECGenParameterSpec("secp256r1")) }.generateKeyPair()
    private fun b64(bytes: ByteArray) = Base64.getUrlEncoder().withoutPadding().encodeToString(bytes)
    private fun coordinate(bytes: ByteArray) = ByteArray(32).also {
        val raw = bytes.takeLast(32).toByteArray(); raw.copyInto(it, 32 - raw.size)
    }
    private fun keys(): JSONObject {
        val point = (key.public as ECPublicKey).w
        return JSONObject().put("keys", JSONArray().put(JSONObject(mapOf("kid" to "one", "kty" to "EC", "crv" to "P-256", "alg" to "ES256",
            "x" to b64(coordinate(point.affineX.toByteArray())), "y" to b64(coordinate(point.affineY.toByteArray()))))))
    }
    private fun claims(id: Boolean = false) = JSONObject().put("iss", config.issuer)
        .put("sub", "ab01234567890123456789012345").put("aud", if (id) config.clientId else config.station)
        .put("client_id", config.clientId).put("scope", "openid profile astation.remote")
        .put("iat", now).put("exp", now + if (id) 3600 else 900).put("auth_time", now - 300)
    private fun jwt(claims: JSONObject = claims(), id: Boolean = false, alg: String = "ES256", typ: String = if (id) "JWT" else "at+jwt"): String {
        val input = b64(JSONObject().put("alg", alg).put("typ", typ).put("kid", "one").toString().toByteArray()) + "." + b64(claims.toString().toByteArray())
        val der = Signature.getInstance("SHA256withECDSA").run { initSign(key.private); update(input.toByteArray()); sign() }
        var cursor = 2
        fun component(): ByteArray {
            check(der[cursor++].toInt() == 2)
            val size = der[cursor++].toInt() and 255
            return coordinate(der.copyOfRange(cursor, cursor + size)).also { cursor += size }
        }
        return input + "." + b64(component() + component())
    }
    private fun verify(value: String, id: Boolean = false, keys: JSONObject = keys()) =
        MobileTokenValidator.verify(value, keys, config, id, now) { it }
    private fun rejected(body: () -> Unit) {
        try { body(); fail("Invalid signed token accepted") }
        catch (e: MobileLoginFailure) { assertEquals("invalid_response", e.code) }
    }

    @Test fun stationAccessAndIdTokensAreVerifiedWithRealSignatures() {
        assertEquals(config.clientId, verify(jwt()).getString("client_id"))
        assertEquals(config.clientId, verify(jwt(claims(true), id = true), id = true).getString("aud"))
    }
    @Test fun portalProductionOtherClientAndMissingScopeAreRefused() {
        for ((field, value) in listOf("aud" to "https://dev.agora.build", "aud" to "https://station.agora.build",
            "iss" to "https://auth.agora.build", "client_id" to "astation-ios", "scope" to "openid profile")) {
            rejected { verify(jwt(claims().put(field, value))) }
        }
    }
    @Test fun signatureTypeAlgorithmAndKeySubstitutionAreRefused() {
        rejected { verify(jwt(alg = "none")) }
        rejected { verify(jwt(typ = "JWT")) }
        val token = jwt(); val pieces = token.split('.')
        val tampered = b64(claims().put("auth_time", now - 600).toString().toByteArray())
        rejected { verify(pieces[0] + "." + tampered + "." + pieces[2]) }
        rejected { verify(token, keys = keys().apply { getJSONArray("keys").getJSONObject(0).put("kid", "different") }) }
        rejected { verify(token + "=") }
    }
    @Test fun lifetimeAndAuthenticationProofAreStrict() {
        for ((field, value) in listOf("iat" to now + 31, "exp" to now, "exp" to now + 901,
            "auth_time" to now + 31, "nbf" to now + 1, "iat" to true, "iat" to 0.5)) {
            rejected { verify(jwt(claims().put(field, value))) }
        }
        rejected { verify(jwt(claims().apply { remove("auth_time") })) }
    }
    @Test fun idTokenCannotUseTheOtherMobileClient() {
        rejected { verify(jwt(claims(true).put("aud", "astation-ios"), id = true), id = true) }
        rejected { verify(jwt(claims(true).put("azp", "different"), id = true), id = true) }
    }
}
