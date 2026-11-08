package build.agora.astation_mobile

import com.google.crypto.tink.subtle.X25519
import java.math.BigInteger
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class MobileDeviceCryptoTest {
    private fun hex(value: String): ByteArray = value.chunked(2).map { it.toInt(16).toByte() }.toByteArray()

    @Test fun hpkeUsesThePublishedRFC9180BaseVector() {
        val vector = JSONObject(javaClass.getResource("/hpke-base-x25519.json")!!.readText())
        val privateKey = hex(vector.getString("skRm"))
        assertArrayEquals(hex(vector.getString("pkRm")), X25519.publicFromPrivate(privateKey))
        val enc = hex(vector.getString("enc"))
        val info = hex(vector.getString("info"))
        val encryption = vector.getJSONObject("encryption")
        val ciphertext = hex(encryption.getString("ct"))
        val aad = hex(encryption.getString("aad"))
        assertArrayEquals(hex(encryption.getString("pt")), MobileHpke.open(privateKey, enc, ciphertext, info, aad))
        for ((changedCiphertext, changedInfo, changedAAD) in listOf(
            Triple(ciphertext.copyOf().also { it[0] = (it[0].toInt() xor 1).toByte() }, info, aad),
            Triple(ciphertext, byteArrayOf(), aad), Triple(ciphertext, info, byteArrayOf()))) {
            assertThrows(Exception::class.java) { MobileHpke.open(privateKey, enc, changedCiphertext, changedInfo, changedAAD) }
        }
    }

    @Test fun hpkeRejectsLowOrderPeersAndUnboundedInputs() {
        val privateKey = X25519.generatePrivateKey()
        assertThrows(Exception::class.java) { MobileHpke.open(privateKey, ByteArray(32), ByteArray(32), byteArrayOf(), byteArrayOf()) }
        assertThrows(MobileDeviceIdentityFailure::class.java) { MobileHpke.open(privateKey, ByteArray(31), ByteArray(32), byteArrayOf(), byteArrayOf()) }
        assertThrows(MobileDeviceIdentityFailure::class.java) { MobileHpke.open(privateKey, ByteArray(32), ByteArray(262_145), byteArrayOf(), byteArrayOf()) }
    }

    @Test fun p256DERIsConvertedToTheSameCanonicalLowSFormatAsApple() {
        val order = BigInteger("ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551", 16)
        fun der(r: BigInteger, s: BigInteger): ByteArray {
            fun integer(value: BigInteger) = value.toByteArray().let { byteArrayOf(2, it.size.toByte()) + it }
            val values = integer(r) + integer(s)
            return byteArrayOf(0x30, values.size.toByte()) + values
        }
        val expected = ByteArray(64).also { it[31] = 1; it[63] = 2 }
        assertArrayEquals(expected, MobileP256Signature.fromDER(der(BigInteger.ONE, BigInteger.TWO)))
        assertArrayEquals(expected, MobileP256Signature.fromDER(der(BigInteger.ONE, order - BigInteger.TWO)))
        for (invalid in listOf(der(BigInteger.ZERO, BigInteger.ONE), der(order, BigInteger.ONE),
            der(BigInteger.ONE, BigInteger.valueOf(-1)), byteArrayOf(0x30, 6, 2, 2, 0, 1, 2, 0))) {
            assertThrows(MobileDeviceIdentityFailure::class.java) { MobileP256Signature.fromDER(invalid) }
        }
    }
}
