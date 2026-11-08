package build.agora.astation_mobile

import com.google.crypto.tink.hybrid.internal.HpkeContext
import com.google.crypto.tink.hybrid.internal.HpkeKemPrivateKey
import com.google.crypto.tink.hybrid.internal.HpkePrimitiveFactory
import com.google.crypto.tink.subtle.X25519
import com.google.crypto.tink.util.Bytes
import java.math.BigInteger
import java.util.UUID
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import uniffi.atem_client_ffi.SignLabelKind
import uniffi.atem_client_ffi.SignRequest
import uniffi.atem_client_ffi.SigningPurpose
import uniffi.atem_client_ffi.signingInput

/** Isolates Tink's fixed RFC 9180 suite; never assemble HPKE primitives in application code. */
internal object MobileHpke {
    fun open(privateKey: ByteArray, enc: ByteArray, ciphertext: ByteArray, info: ByteArray, aad: ByteArray): ByteArray {
        if (privateKey.size != 32 || enc.size != 32 || ciphertext.size !in 16..262_144 || info.size > 65_536 || aad.size > 65_536)
            throw MobileDeviceIdentityFailure("invalid_ciphertext")
        // This pinned Tink context API is needed because HybridDecrypt has no arbitrary-AAD parameter.
        val key = HpkeKemPrivateKey(Bytes.copyFrom(privateKey), Bytes.copyFrom(X25519.publicFromPrivate(privateKey)))
        val recipient = HpkeContext.createRecipientContext(enc, key,
            HpkePrimitiveFactory.createKem(byteArrayOf(0, 0x20)),
            HpkePrimitiveFactory.createKdf(byteArrayOf(0, 1)),
            HpkePrimitiveFactory.createAead(byteArrayOf(0, 3)), info)
        return recipient.open(ciphertext, aad)
    }
}

internal object MobileP256Signature {
    private val order = BigInteger("ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551", 16)

    fun fromDER(der: ByteArray): ByteArray {
        if (der.size !in 8..72 || der[0] != 0x30.toByte() || der[1].toInt() != der.size - 2)
            throw MobileDeviceIdentityFailure("invalid_signature")
        var offset = 2
        fun scalar(): BigInteger {
            if (offset + 2 > der.size || der[offset++] != 2.toByte()) throw MobileDeviceIdentityFailure("invalid_signature")
            val size = der[offset++].toInt()
            if (size !in 1..33 || offset + size > der.size) throw MobileDeviceIdentityFailure("invalid_signature")
            val raw = der.copyOfRange(offset, offset + size)
            offset += size
            if (raw[0] < 0 || (raw.size > 1 && raw[0] == 0.toByte() && raw[1] >= 0)) throw MobileDeviceIdentityFailure("invalid_signature")
            return BigInteger(raw).also { if (it.signum() <= 0 || it >= order) throw MobileDeviceIdentityFailure("invalid_signature") }
        }
        val r = scalar()
        val s = scalar().let { if (it > order.shiftRight(1)) order - it else it }
        if (offset != der.size) throw MobileDeviceIdentityFailure("invalid_signature")
        fun fixed(value: BigInteger): ByteArray = value.toByteArray().let {
            if (it.size == 33) it.copyOfRange(1, 33) else ByteArray(32 - it.size) + it
        }
        return fixed(r) + fixed(s)
    }
}

/** Matches the shared R9 channel-only owner gate. Lock/background invalidates its generation. */
internal class MobileDeviceChannelSigner(
    private val deviceId: String, private val now: () -> Long, private val foreground: () -> Boolean,
    private val confirm: suspend () -> Boolean, private val primitive: (SignRequest) -> ByteArray,
) {
    private val mutex = Mutex()
    private val stateLock = Any()
    private var confirmedAt: Long? = null
    private var generation = UUID.randomUUID()

    companion object {
        fun validate(request: SignRequest, keyId: String) {
            if (request.keyId != keyId || request.purpose != SigningPurpose.CHANNEL || request.freshConfirmation ||
                request.bodyJson != null || request.label != "atem-ch1-client-sig-v1" || request.input.size < 32 ||
                !request.input.contentEquals(signingInput(SignLabelKind.CHANNEL_CLIENT, request.input.takeLast(32).toByteArray())))
                throw MobileDeviceIdentityFailure("invalid_signing_request")
        }
    }

    fun invalidate() = synchronized(stateLock) { generation = UUID.randomUUID(); confirmedAt = null }

    suspend fun sign(request: SignRequest, current: () -> Boolean): ByteArray = mutex.withLock {
        validate(request, deviceId)
        val epoch = synchronized(stateLock) { generation }
        val job = currentCoroutineContext()
        fun checkContext() {
            job.ensureActive()
            synchronized(stateLock) {
                if (epoch != generation || !current() || !foreground()) throw MobileDeviceIdentityFailure("context_changed")
            }
        }
        try {
            checkContext()
            val time = now()
            if (synchronized(stateLock) { confirmedAt?.let { time >= it && time - it < 300_000 } } != true) {
                if (!confirm()) throw MobileDeviceIdentityFailure("owner_denied")
                synchronized(stateLock) { checkContext(); confirmedAt = now() }
            }
            synchronized(stateLock) {
                checkContext()
                val signingTime = now()
                if (confirmedAt?.let { signingTime >= it && signingTime - it < 300_000 } != true)
                    throw MobileDeviceIdentityFailure("owner_expired")
                primitive(request)
            }
        } catch (error: Exception) { invalidate(); throw error }
    }
}
