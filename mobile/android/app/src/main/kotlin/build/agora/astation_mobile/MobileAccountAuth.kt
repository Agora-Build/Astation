package build.agora.astation_mobile

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import net.openid.appauth.AuthorizationRequest
import net.openid.appauth.AuthorizationResponse
import net.openid.appauth.AuthorizationService
import net.openid.appauth.AuthorizationServiceConfiguration
import net.openid.appauth.ResponseTypeValues
import org.json.JSONObject
import uniffi.atem_client_ffi.canonicalJson
import java.net.HttpURLConnection
import java.net.URI
import java.net.URLEncoder
import java.io.ByteArrayOutputStream
import java.security.KeyStore
import java.security.SecureRandom
import java.util.UUID
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

internal class MobileLoginFailure(val code: String) : Exception(when (code) {
    "cancelled" -> "Account sign-in was cancelled."
    "sign_in_required" -> "Sign in to Agora.Build again."
    "changed" -> "The account session changed. Try again."
    "storage" -> "Unlock this device to access your saved sign-in."
    "busy" -> "Finish the current sign-in first."
    "station_unavailable" -> "Station could not verify this sign-in. Try again."
    "unavailable" -> "The account service is unavailable. Try again."
    else -> "The account service returned an invalid sign-in."
})

internal data class MobileOAuthConfig(val development: Boolean) {
    val issuer = if (development) "https://auth.dev.agora.build" else "https://auth.agora.build"
    val station = if (development) "https://station-dev.agora.build" else "https://station.agora.build"
    val clientId = "astation-android"
    val redirect = "build.agora.astation.android:/oauth/callback"

    fun authorizationRequest(endpoints: AuthorizationServiceConfiguration): AuthorizationRequest =
        AuthorizationRequest.Builder(endpoints, clientId, ResponseTypeValues.CODE, Uri.parse(redirect))
            .setScope("openid profile offline_access astation.remote")
            // OIDC requires explicit consent before issuing an offline refresh token.
            .setPrompt("consent")
            .setState(random()).setNonce(random()).setCodeVerifier(random())
            .setAdditionalParameters(mapOf("resource" to station)).build()

    private fun random(): String = Base64.encodeToString(ByteArray(32).also { SecureRandom().nextBytes(it) },
        Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING)
}

private data class MobileLoginSession(
    val subject: String, val refresh: String, val authTime: Long,
    val access: String = "", val expires: Long = 0,
)

/** Refresh credentials are device-bound and encrypted; no token is passed to Flutter. */
private class MobileTokenStorage(context: Context, private val config: MobileOAuthConfig) {
    private val preferences = context.getSharedPreferences("mobile.oidc.v1", Context.MODE_PRIVATE)
    private val slot = if (config.development) "development" else "production"
    private fun key(): SecretKey {
        val alias = "build.agora.astation.mobile.oidc.v1"
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(alias, null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setRandomizedEncryptionRequired(true).build())
        }.generateKey()
    }
    fun read(): Pair<MobileLoginSession, Boolean>? {
        val encrypted = preferences.getString(slot, null) ?: return null
        try {
            val data = Base64.decode(encrypted, Base64.NO_WRAP)
            require(data.size > 28)
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, data.copyOfRange(0, 12)))
            cipher.updateAAD((slot + "|" + config.issuer + "|" + config.station).toByteArray())
            val value = JSONObject(String(cipher.doFinal(data.copyOfRange(12, data.size)), Charsets.UTF_8))
            return MobileLoginSession(value.getString("sub"), value.getString("refresh"), value.getLong("auth_time")) to value.getBoolean("pending")
        } catch (_: Exception) { throw MobileLoginFailure("storage") }
    }
    fun write(session: MobileLoginSession?, pending: Boolean = false) {
        try {
            val edit = preferences.edit()
            if (session == null) edit.remove(slot)
            else {
                val value = JSONObject().put("sub", session.subject).put("refresh", session.refresh)
                    .put("auth_time", session.authTime).put("pending", pending)
                val cipher = Cipher.getInstance("AES/GCM/NoPadding")
                cipher.init(Cipher.ENCRYPT_MODE, key())
                cipher.updateAAD((slot + "|" + config.issuer + "|" + config.station).toByteArray())
                val data = cipher.iv + cipher.doFinal(value.toString().toByteArray(Charsets.UTF_8))
                edit.putString(slot, Base64.encodeToString(data, Base64.NO_WRAP))
            }
            if (!edit.commit()) throw MobileLoginFailure("storage")
        } catch (_: Exception) { throw MobileLoginFailure("storage") }
    }
}

internal class MobileAccountAuth(context: Context, val config: MobileOAuthConfig) {
    private val service = AuthorizationService(context)
    private val storage = MobileTokenStorage(context, config)
    private val rotation = Mutex()
    private var generation = UUID.randomUUID()
    private var request: AuthorizationRequest? = null
    private var preparing = false
    private var session: MobileLoginSession? = null
    private var uncertain = false
    private var accountConfirmed = false
    val subject: String? get() = session?.subject?.takeIf { accountConfirmed }
    private var keys: JSONObject? = null
    private var keysAt = 0L
    private var metadata: JSONObject? = null
    private var metadataAt = 0L

    private fun checked(epoch: UUID) { if (generation != epoch) throw MobileLoginFailure("changed") }
    private fun endpoint(value: String): String {
        val uri = URI(value)
        val issuer = URI(config.issuer)
        if (uri.scheme != "https" || uri.host != issuer.host || uri.port != issuer.port ||
            uri.userInfo != null || uri.fragment != null || uri.query != null) throw MobileLoginFailure("invalid_response")
        return value
    }
    private suspend fun http(url: String, fields: Map<String, String>? = null, token: String? = null): Pair<Int, JSONObject> = withContext(Dispatchers.IO) {
        try {
            val connection = URI(url).toURL().openConnection() as HttpURLConnection
            try {
                connection.instanceFollowRedirects = false
                connection.connectTimeout = 10_000
                connection.readTimeout = 20_000
                connection.useCaches = false
                token?.let { connection.setRequestProperty("Authorization", "Bearer $it") }
                if (fields != null) {
                    connection.requestMethod = "POST"
                    connection.doOutput = true
                    connection.setRequestProperty("Content-Type", "application/x-www-form-urlencoded")
                    val body = fields.entries.joinToString("&") { (key, value) ->
                        URLEncoder.encode(key, "UTF-8") + "=" + URLEncoder.encode(value, "UTF-8") }
                    connection.outputStream.use { it.write(body.toByteArray(Charsets.UTF_8)) }
                }
                val status = connection.responseCode
                val bytes = (if (status in 200..299) connection.inputStream else connection.errorStream)
                    ?.use { stream ->
                        val output = ByteArrayOutputStream()
                        val buffer = ByteArray(4096)
                        while (true) {
                            val count = stream.read(buffer)
                            if (count < 0) break
                            if (output.size() + count > 65_536) throw MobileLoginFailure("invalid_response")
                            output.write(buffer, 0, count)
                        }
                        output.toByteArray()
                    } ?: throw MobileLoginFailure("unavailable")
                status to JSONObject(canonicalJson(MobileTokenValidator.utf8(bytes)))
            } finally { connection.disconnect() }
        } catch (e: MobileLoginFailure) { throw e }
        catch (_: Exception) { throw MobileLoginFailure("unavailable") }
    }
    private suspend fun discovery(): JSONObject {
        val now = System.currentTimeMillis()
        metadata?.let { if (now - metadataAt in 0..59_999) return it }
        val (status, value) = http(config.issuer + "/.well-known/openid-configuration")
        if (status != 200 || value.optString("issuer") != config.issuer) throw MobileLoginFailure("unavailable")
        for (field in listOf("authorization_endpoint", "token_endpoint", "jwks_uri")) endpoint(value.getString(field))
        metadata = value; metadataAt = now
        return value
    }
    suspend fun signInIntent(): Intent {
        if (preparing || request != null) throw MobileLoginFailure("busy")
        generation = UUID.randomUUID()
        preparing = true
        val epoch = generation
        try {
            val metadata = discovery()
            checked(epoch)
            val endpoints = AuthorizationServiceConfiguration(Uri.parse(metadata.getString("authorization_endpoint")), Uri.parse(metadata.getString("token_endpoint")))
            val attempt = config.authorizationRequest(endpoints)
            val intent = service.getAuthorizationRequestIntent(attempt)
            request = attempt
            return intent
        } finally { if (generation == epoch) preparing = false }
    }
    suspend fun finishSignIn(data: Intent?) {
        val epoch = generation
        val attempt = request ?: throw MobileLoginFailure("changed")
        try {
            val response = data?.let(AuthorizationResponse::fromIntent) ?: throw MobileLoginFailure("cancelled")
            if (response.state != attempt.state || response.request.redirectUri.toString() != config.redirect ||
                response.request.clientId != config.clientId || response.authorizationCode.isNullOrEmpty()) throw MobileLoginFailure("invalid_response")
            val value = token(mapOf("grant_type" to "authorization_code", "code" to response.authorizationCode!!,
                "redirect_uri" to config.redirect, "code_verifier" to (attempt.codeVerifier ?: throw MobileLoginFailure("invalid_response"))))
            val id = verified(value.getString("id_token"), id = true)
            if (id.optString("nonce") != attempt.nonce) throw MobileLoginFailure("invalid_response")
            val next = loginSession(value, id.getString("sub"))
            if (MobileTokenValidator.integer(id, "auth_time") != next.authTime) throw MobileLoginFailure("invalid_response")
            checked(epoch)
            storage.write(next)
            session = next; uncertain = false; accountConfirmed = true
        } finally { if (generation == epoch) request = null }
    }
    fun cancelSignIn() { request = null; preparing = false }
    fun signOut() {
        generation = UUID.randomUUID(); request = null; preparing = false; session = null; accountConfirmed = false; uncertain = true
        storage.write(null)
        uncertain = false
    }
    fun dispose() { generation = UUID.randomUUID(); request = null; preparing = false; session = null; accountConfirmed = false; service.dispose() }
    suspend fun restore() {
        val epoch = generation
        val record = storage.read() ?: return
        if (record.second) throw MobileLoginFailure("sign_in_required")
        accountConfirmed = false
        session = record.first
        try { accessToken(); checked(epoch) }
        catch (e: Exception) { if (epoch == generation) session = null; throw e }
    }
    suspend fun refresh() { accessToken() }
    private suspend fun token(fields: Map<String, String>): JSONObject {
        val (status, value) = http(endpoint(discovery().getString("token_endpoint")),
            fields + mapOf("client_id" to config.clientId, "resource" to config.station))
        if (status != 200) throw MobileLoginFailure(if (value.optString("error") == "invalid_grant") "sign_in_required" else if (status >= 500) "unavailable" else "invalid_response")
        return value
    }
    private suspend fun accessToken(force: Boolean = false): String {
        val epoch = generation
        val seen = session?.access
        return rotation.withLock {
            checked(epoch)
            if (uncertain || request != null || preparing) throw MobileLoginFailure("sign_in_required")
            val current = session ?: throw MobileLoginFailure("sign_in_required")
            if (current.expires > System.currentTimeMillis() / 1000 + 60 && (!force || seen != current.access)) return@withLock current.access
            // Persist before sending a one-use refresh token; never replay after a lost reply.
            uncertain = true
            storage.write(current, pending = true)
            try {
                val result = token(mapOf("grant_type" to "refresh_token", "refresh_token" to current.refresh))
                val next = loginSession(result, current.subject)
                if (result.has("id_token")) {
                    val id = verified(result.getString("id_token"), id = true)
                    if (id.getString("sub") != current.subject || MobileTokenValidator.integer(id, "auth_time") != current.authTime) throw MobileLoginFailure("invalid_response")
                }
                if (next.refresh == current.refresh || next.authTime != current.authTime) throw MobileLoginFailure("invalid_response")
                checked(epoch)
                storage.write(next)
                session = next; uncertain = false; accountConfirmed = true
                next.access
            } catch (e: Exception) {
                if (generation == epoch) { session = null }
                throw e
            }
        }
    }
    private suspend fun loginSession(result: JSONObject, subject: String): MobileLoginSession {
        if (!result.getString("token_type").equals("Bearer", ignoreCase = true)) throw MobileLoginFailure("invalid_response")
        val refresh = result.getString("refresh_token")
        if (refresh.isEmpty() || refresh.length > 16384) throw MobileLoginFailure("invalid_response")
        val access = result.getString("access_token")
        val value = verified(access)
        if (value.getString("sub") != subject) throw MobileLoginFailure("invalid_response")
        return MobileLoginSession(subject, refresh, MobileTokenValidator.integer(value, "auth_time"), access, MobileTokenValidator.integer(value, "exp"))
    }
    private suspend fun verified(jwt: String, id: Boolean = false): JSONObject {
        val now = System.currentTimeMillis()
        var current = keys
        if (current == null || now - keysAt !in 0..59_999) {
            val (status, value) = http(endpoint(discovery().getString("jwks_uri")))
            if (status != 200) throw MobileLoginFailure("unavailable")
            current = value; keys = value; keysAt = now
        }
        return MobileTokenValidator.verify(jwt, current, config, id, now / 1000) { canonicalJson(it) }
    }
    suspend fun verifyLogin(): Map<String, Any> {
        val epoch = generation
        val before = session ?: throw MobileLoginFailure("sign_in_required")
        val access = accessToken(force = true)
        checked(epoch)
        val after = session ?: throw MobileLoginFailure("sign_in_required")
        if (before.refresh == after.refresh || before.authTime != after.authTime) throw MobileLoginFailure("invalid_response")
        val (status, body) = http(config.station + "/api/remote/v1/logs/" + "0".repeat(64) + "/entries?after=0", token = access)
        checked(epoch)
        if (status != 404 || body.optJSONObject("error")?.optString("code") != "recovery_record_not_found") throw MobileLoginFailure("station_unavailable")
        return mapOf("clientId" to config.clientId, "station" to config.station, "refreshRotated" to true,
            "authTimeUnchanged" to true, "stationTokenAccepted" to true, "memberChannelVerified" to false)
    }
}
