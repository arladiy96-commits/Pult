package app.pult.tv

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.math.BigInteger
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.MessageDigest
import java.util.Date
import javax.net.ssl.KeyManagerFactory
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLServerSocket
import javax.net.ssl.SSLServerSocketFactory
import javax.security.auth.x500.X500Principal

/** Persistent device-generated TLS identity. Client must pin SHA-256 cert fingerprint. */
object SecureTransport {
    private const val ALIAS = "pult_tv_tls_v1"

    @Synchronized private fun keyStore(): KeyStore {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        if (!ks.containsAlias(ALIAS)) {
            val generator = KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_RSA, "AndroidKeyStore")
            val start = Date(System.currentTimeMillis() - 24L * 3600_000)
            val end = Date(System.currentTimeMillis() + 20L * 365 * 24 * 3600_000)
            generator.initialize(
                KeyGenParameterSpec.Builder(ALIAS,
                    KeyProperties.PURPOSE_SIGN or KeyProperties.PURPOSE_VERIFY)
                    .setKeySize(2048)
                    .setDigests(KeyProperties.DIGEST_SHA256)
                    .setSignaturePaddings(KeyProperties.SIGNATURE_PADDING_RSA_PKCS1, KeyProperties.SIGNATURE_PADDING_RSA_PSS)
                    .setCertificateSubject(X500Principal("CN=Pult TV Companion"))
                    .setCertificateSerialNumber(BigInteger.ONE)
                    .setCertificateNotBefore(start)
                    .setCertificateNotAfter(end)
                    .build()
            )
            generator.generateKeyPair()
        }
        return ks
    }

    fun fingerprint(): String {
        val der = keyStore().getCertificate(ALIAS).encoded
        return MessageDigest.getInstance("SHA-256").digest(der)
            .joinToString(":") { "%02X".format(it) }
    }

    fun serverSocket(port: Int): SSLServerSocket {
        val kmf = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm())
        kmf.init(keyStore(), null)
        val ssl = SSLContext.getInstance("TLS")
        ssl.init(kmf.keyManagers, null, null)
        val socket = (ssl.serverSocketFactory as SSLServerSocketFactory)
            .createServerSocket(port) as SSLServerSocket
        socket.enabledProtocols = socket.supportedProtocols
            .filter { it == "TLSv1.3" || it == "TLSv1.2" }.toTypedArray()
        socket.needClientAuth = false
        socket.reuseAddress = true
        return socket
    }
}
