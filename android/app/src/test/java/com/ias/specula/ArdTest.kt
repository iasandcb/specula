package com.ias.specula

import java.io.IOException
import org.junit.Assert.*
import org.junit.Test

class ArdTest {
    companion object {
        val prime =
            hex(
                "ffffffffffffffffc90fdaa22168c234c4c6628b80dc1cd129024e088a67cc74020bbea63b139b22514a08798e3404ddef9519b3cd3a431b302b0a6df25f14374fe1356d6d51c245e485b576625e7ec6f44c42e9a637ed6b0bff5cb6f406b7edee386bfb5a899fa5ae9f24117c4b1fe649286651ece65381ffffffffffffffff"
            )
        val peer =
            hex(
                "567bd67676e2ece82d1656a441af9505378082a7a0286ecc24f5517362993c027fe35227ffd11844e11eb457648f5151443fd51d6827f0c47642d545a0727896af5a71846368fca550a90dccb06ee16825a33feb2e3c2e9098930968acfb110c53d344663b0acf2e2753bbf8aaf303889918d753ece2dbc96ddcac8fe3793c8d"
            )
    }

    @Test
    fun pythonOpenSslReferenceResponse() {
        assertArrayEquals(
            hex(
                "bb878e78cb825ee14826edb748bc8af0bf401d474cb99685d7341dcfa1fd102dbf401d474cb99685d7341dcfa1fd102dbf401d474cb99685d7341dcfa1fd102d74bb4106d7e514f45fb9468586e0b992bf401d474cb99685d7341dcfa1fd102dbf401d474cb99685d7341dcfa1fd102dbf401d474cb99685d7341dcfa1fd102d1695d0e82c9d7085f1126ee2ae24fc2946f049a0bf366d790360f93e2c090e3551ebf2c4b1a5aa421dbb2c24dd6904882d43e54b7f46cfaaa62b856d9b487a9c8af511b247834673f1d42a7559988bf3129f51fd3c370f3bdbf4c400b11cf8869a7b384d5dc4daa6bd085edb0f32363c7fcbf78e51d846c790c1b26269dda201"
            ),
            ARD.response(
                2,
                prime,
                peer,
                "alex",
                "암호123",
                ByteArray(32) { 3 },
                ByteArray(128) { 0xaa.toByte() },
            ),
        )
    }

    @Test
    fun degenerateDhRejected() {
        for (value in listOf(ByteArray(128), ByteArray(127) + byteArrayOf(1), prime)) assertThrows(
            IOException::class.java
        ) {
            ARD.response(2, prime, value, "alex", "secret")
        }
        assertThrows(IOException::class.java) { ARD.response(1, prime, peer, "alex", "secret") }
        assertThrows(IOException::class.java) {
            ARD.response(2, prime, peer.copyOf(127), "alex", "secret")
        }
        assertThrows(IOException::class.java) {
            ARD.response(2, ByteArray(128) { 0xff.toByte() }, peer, "alex", "secret")
        }
    }
}
