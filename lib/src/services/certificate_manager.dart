import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:basic_utils/basic_utils.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

Map<String, String> _generateKeypairAndCert(int keySize) {
  final pair = CryptoUtils.generateRSAKeyPair(keySize: keySize);
  final publicKey = pair.publicKey as RSAPublicKey;
  final privateKey = pair.privateKey as RSAPrivateKey;

  const identityName = 'androidtvremote';

  final csrPem = X509Utils.generateRsaCsrPem(
    {'CN': identityName},
    privateKey,
    publicKey,
  );

  final certPem = X509Utils.generateSelfSignedCertificate(
    privateKey,
    csrPem,
    3650,
    sans: const [identityName],
    cA: true,
    pathLenConstraint: 0,
    serialNumber: '1000',
    notBefore: DateTime.now().toUtc().subtract(
          const Duration(minutes: 5),
        ),
  );

  final keyPem = CryptoUtils.encodeRSAPrivateKeyToPem(privateKey);

  return {
    'cert': certPem,
    'key': keyPem,
  };
}

class CertificateManager {
  // v2 intentionally forces regeneration of the old minimal certificate.
  static const _certKey = 'x96_client_cert_v2';
  static const _keyKey = 'x96_client_key_v2';

  final _storage = const FlutterSecureStorage();

  String? _certPem;
  String? _keyPem;

  Future<void> ensureReady() async {
    if (_certPem != null && _keyPem != null) return;

    _certPem = await _storage.read(key: _certKey);
    _keyPem = await _storage.read(key: _keyKey);

    if (_certPem == null || _keyPem == null) {
      final result = await compute(_generateKeypairAndCert, 2048);
      _certPem = result['cert'];
      _keyPem = result['key'];

      await _storage.write(key: _certKey, value: _certPem);
      await _storage.write(key: _keyKey, value: _keyPem);
    }
  }

  Future<SecurityContext> buildSecurityContext() async {
    await ensureReady();

    final context = SecurityContext(withTrustedRoots: false);
    context.useCertificateChainBytes(utf8.encode(_certPem!));
    context.usePrivateKeyBytes(utf8.encode(_keyPem!));
    return context;
  }

  Future<String> getClientCertPem() async {
    await ensureReady();
    return _certPem!;
  }

  Future<Uint8List> getClientCertDer() async {
    await ensureReady();
    return CryptoUtils.getBytesFromPEMString(_certPem!);
  }
}
