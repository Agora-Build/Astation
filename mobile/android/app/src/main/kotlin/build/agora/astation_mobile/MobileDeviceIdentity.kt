package build.agora.astation_mobile

import android.app.KeyguardManager
import android.content.Context
import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.system.Os
import android.system.OsConstants
import android.util.AtomicFile
import android.util.Base64
import com.google.crypto.tink.subtle.X25519
import java.io.Closeable
import java.io.File
import java.io.RandomAccessFile
import java.math.BigInteger
import java.net.URI
import java.nio.channels.FileLock
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.PrivateKey
import java.security.Signature
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec
import java.util.UUID
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import org.json.JSONObject
import uniffi.atem_client_ffi.SignRequest
import uniffi.atem_client_ffi.canonicalJson
import uniffi.atem_client_ffi.hashFields

internal class MobileDeviceIdentityFailure(val reason: String) : Exception("Protected device identity: $reason")

/** Immutable native identity. A saved key or an account login is never membership. */
internal class MobileDeviceIdentity private constructor(
    private val context: Context, private val issuer: String, private val accountId: String,
    private val scope: String, private val file: AtomicFile, private val lockFile: RandomAccessFile,
    private val fileLock: FileLock,
) : Closeable {
    private val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
    private val authAlias = "build.agora.astation.device.auth.$scope"
    private val wrappingAlias = "build.agora.astation.device.wrap.$scope"
    private val aad = "astation-native-device-key-v1|$scope".toByteArray(Charsets.UTF_8)
    private var saved = byteArrayOf()
    private var closed = false
    private var uncertain = false
    private lateinit var id: String
    private lateinit var authPublic: ByteArray
    private lateinit var encryptionPublic: ByteArray

    val deviceId: String get() = id
    val authPublicKey: ByteArray get() = authPublic.copyOf()
    val encryptionPublicKey: ByteArray get() = encryptionPublic.copyOf()

    companion object {
        fun open(context: Context, issuer: String, accountId: String): MobileDeviceIdentity {
            val origin = URI(issuer)
            if (origin.scheme != "https" || origin.host.isNullOrEmpty() || origin.rawPath != "" || origin.rawQuery != null ||
                origin.rawFragment != null || origin.rawUserInfo != null || origin.toASCIIString() != issuer ||
                !Regex("[A-Za-z0-9._:-]{1,128}").matches(accountId)) throw MobileDeviceIdentityFailure("invalid_context")
            val scope = hashFields(listOf("astation-native-device-identity-v1", issuer, accountId).map { it.toByteArray(Charsets.UTF_8) })
            val directory = File(context.noBackupFilesDir, "device-identities-v1")
            if (!directory.isDirectory && !directory.mkdirs()) throw MobileDeviceIdentityFailure("storage")
            val descriptor = RandomAccessFile(File(directory, "$scope.lock"), "rw")
            try {
                val lock = descriptor.channel.tryLock() ?: throw MobileDeviceIdentityFailure("busy")
                val identity = MobileDeviceIdentity(context.applicationContext, issuer, accountId, scope,
                    AtomicFile(File(directory, "$scope.bin")), descriptor, lock)
                try { identity.initialize(); return identity }
                catch (error: Exception) { identity.close(); throw error }
            } catch (error: Exception) { descriptor.close(); throw error }
        }
    }

    private fun requireUnlocked() {
        if (context.getSystemService(KeyguardManager::class.java).isDeviceLocked) throw MobileDeviceIdentityFailure("locked")
    }

    private fun wrappingKey(): SecretKey = keyStore.getKey(wrappingAlias, null) as? SecretKey
        ?: throw MobileDeviceIdentityFailure("missing_key")

    private fun initialize() {
        requireUnlocked()
        if (file.baseFile.exists() || File(file.baseFile.path + ".bak").exists()) saved = file.openRead().use { it.readBytesBounded() }
        else {
            // A missing record beside existing aliases can be an interrupted or lost save. Never replace those keys.
            if (keyStore.containsAlias(authAlias) || keyStore.containsAlias(wrappingAlias)) throw MobileDeviceIdentityFailure("incomplete_setup")
            val authSpec = KeyGenParameterSpec.Builder(authAlias, KeyProperties.PURPOSE_SIGN or KeyProperties.PURPOSE_VERIFY)
                .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1")).setDigests(KeyProperties.DIGEST_SHA256)
            val wrapSpec = KeyGenParameterSpec.Builder(wrappingAlias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setRandomizedEncryptionRequired(true)
            if (Build.VERSION.SDK_INT >= 28) {
                authSpec.setUnlockedDeviceRequired(true)
                wrapSpec.setUnlockedDeviceRequired(true)
            }
            KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, "AndroidKeyStore").apply { initialize(authSpec.build()) }.generateKeyPair()
            KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply { init(wrapSpec.build()) }.generateKey()
            val privateX = X25519.generatePrivateKey()
            try {
                val record = JSONObject().put("v", 1).put("issuer", issuer).put("account", accountId)
                    .put("device", "astation-" + UUID.randomUUID()).put("auth", b64(actualAuthPublicKey()))
                    .put("enc", b64(X25519.publicFromPrivate(privateX))).put("private_enc", b64(privateX))
                val cipher = Cipher.getInstance("AES/GCM/NoPadding")
                cipher.init(Cipher.ENCRYPT_MODE, wrappingKey()); cipher.updateAAD(aad)
                val encrypted = cipher.iv + cipher.doFinal(record.toString().toByteArray(Charsets.UTF_8))
                val output = file.startWrite()
                try { output.write(encrypted); output.fd.sync(); file.finishWrite(output) }
                catch (error: Exception) { file.failWrite(output); throw error }
                val directory = Os.open(file.baseFile.parentFile!!.path, OsConstants.O_RDONLY, 0)
                try { Os.fsync(directory) } finally { Os.close(directory) }
                saved = encrypted
                if (!file.openRead().use { it.readBytesBounded() }.contentEquals(saved)) throw MobileDeviceIdentityFailure("storage")
            } finally { privateX.fill(0) }
        }
        val record = decryptRecord()
        if (record.getInt("v") != 1 || record.getString("issuer") != issuer || record.getString("account") != accountId ||
            !Regex("astation-[A-Za-z0-9-]{36}").matches(record.getString("device"))) throw MobileDeviceIdentityFailure("invalid_record")
        id = record.getString("device")
        authPublic = decode(record.getString("auth"), 65)
        encryptionPublic = decode(record.getString("enc"), 32)
        if (!actualAuthPublicKey().contentEquals(authPublic)) throw MobileDeviceIdentityFailure("changed_key")
        val privateX = decode(record.getString("private_enc"), 32)
        try {
            if (!X25519.publicFromPrivate(privateX).contentEquals(encryptionPublic)) throw MobileDeviceIdentityFailure("changed_key")
        } finally { privateX.fill(0) }
    }

    private fun actualAuthPublicKey(): ByteArray {
        val key = keyStore.getCertificate(authAlias)?.publicKey as? ECPublicKey ?: throw MobileDeviceIdentityFailure("missing_key")
        fun fixed(value: BigInteger): ByteArray = value.toByteArray().let { bytes ->
            if (bytes.size > 32) bytes.copyOfRange(bytes.size - 32, bytes.size) else ByteArray(32 - bytes.size) + bytes
        }
        return byteArrayOf(4) + fixed(key.w.affineX) + fixed(key.w.affineY)
    }

    private fun decryptRecord(): JSONObject {
        if (saved.size !in 29..65_536) throw MobileDeviceIdentityFailure("invalid_record")
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, wrappingKey(), GCMParameterSpec(128, saved.copyOfRange(0, 12)))
        cipher.updateAAD(aad)
        val plaintext = cipher.doFinal(saved.copyOfRange(12, saved.size))
        try { return JSONObject(canonicalJson(MobileTokenValidator.utf8(plaintext))) }
        finally { plaintext.fill(0) }
    }

    private fun checkStorage() {
        if (closed || uncertain) throw MobileDeviceIdentityFailure("reload_required")
        try {
            requireUnlocked()
            if (!file.openRead().use { it.readBytesBounded() }.contentEquals(saved)) throw MobileDeviceIdentityFailure("changed_record")
            if (!actualAuthPublicKey().contentEquals(authPublic)) throw MobileDeviceIdentityFailure("changed_key")
        } catch (error: Exception) { uncertain = true; throw error }
    }

    fun channelSigner(now: () -> Long, foreground: () -> Boolean, confirm: suspend () -> Boolean): MobileDeviceChannelSigner =
        MobileDeviceChannelSigner(deviceId, now, foreground, confirm, ::signChannel)

    @Synchronized
    private fun signChannel(request: SignRequest): ByteArray {
        checkStorage()
        MobileDeviceChannelSigner.validate(request, deviceId)
        return sign(request.input)
    }

    private fun sign(input: ByteArray): ByteArray {
        val privateKey = keyStore.getKey(authAlias, null) as? PrivateKey ?: throw MobileDeviceIdentityFailure("missing_key")
        val der = Signature.getInstance("SHA256withECDSA").run { initSign(privateKey); update(input); sign() }
        return MobileP256Signature.fromDER(der)
    }

    suspend fun enrollmentRequest(invitation: MobileEnrollmentInvitation, station: String, name: String,
        now: () -> Long, current: () -> Boolean, confirm: suspend () -> Boolean, persist: (String) -> Unit): String {
        val job = currentCoroutineContext()
        fun check() {
            job.ensureActive()
            if (!current()) throw MobileDeviceIdentityFailure("context_changed")
            invitation.validate(issuer, accountId, station, now())
            synchronized(this) { checkStorage() }
        }
        check()
        if (!confirm()) throw MobileDeviceIdentityFailure("owner_denied")
        check()
        val request = synchronized(this) {
            check()
            MobileDeviceEnrollment.request(invitation, deviceId, authPublicKey, encryptionPublicKey, name, now(), ::sign)
        }
        persist(request)
        check()
        return request
    }

    @Synchronized
    fun acceptEnrollment(handoff: String, invitation: MobileEnrollmentInvitation, request: String, station: String,
        log: uniffi.atem_client_ffi.MembershipLog, now: uniffi.atem_client_ffi.HostClock,
        persist: (ByteArray) -> Unit): List<uniffi.atem_client_ffi.AccountKey> {
        checkStorage()
        invitation.validate(issuer, accountId, station, now.wallMs.toLong())
        return MobileDeviceEnrollment.accept(handoff, invitation, request, deviceId, authPublicKey, encryptionPublicKey,
            log, now, ::open, persist)
    }

    @Synchronized
    fun sharedSecret(peer: ByteArray): ByteArray = withEncryptionKey { privateX ->
        if (peer.size != 32) throw MobileDeviceIdentityFailure("invalid_peer")
        X25519.computeSharedSecret(privateX, peer)
    }

    @Synchronized
    fun open(enc: ByteArray, ciphertext: ByteArray, info: ByteArray, aad: ByteArray): ByteArray = withEncryptionKey { privateX ->
        MobileHpke.open(privateX, enc, ciphertext, info, aad)
    }

    private fun <T> withEncryptionKey(operation: (ByteArray) -> T): T {
        checkStorage()
        val privateX = decode(decryptRecord().getString("private_enc"), 32)
        try { return operation(privateX) }
        finally { privateX.fill(0) }
    }

    @Synchronized
    override fun close() {
        if (!closed) {
            closed = true
            saved.fill(0)
            try { fileLock.release() } finally { lockFile.close() }
        }
    }

    private fun java.io.InputStream.readBytesBounded(): ByteArray {
        val output = java.io.ByteArrayOutputStream()
        val buffer = ByteArray(4096)
        while (true) {
            val count = read(buffer)
            if (count < 0) return output.toByteArray()
            if (output.size() + count > 65_536) throw MobileDeviceIdentityFailure("invalid_record")
            output.write(buffer, 0, count)
        }
    }

    private fun b64(bytes: ByteArray) = Base64.encodeToString(bytes, Base64.URL_SAFE or Base64.NO_PADDING or Base64.NO_WRAP)
    private fun decode(value: String, count: Int): ByteArray {
        val result = Base64.decode(value, Base64.URL_SAFE or Base64.NO_PADDING or Base64.NO_WRAP)
        if (result.size != count || b64(result) != value) throw MobileDeviceIdentityFailure("invalid_record")
        return result
    }
}
