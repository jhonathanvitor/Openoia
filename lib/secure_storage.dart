import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

/// Secure local storage vault + Linux Secret Service (libsecret / GNOME Keyring) integration.
///
/// Security architecture:
/// 1. Sensitive credentials (VPN passwords, SSH passwords, key passphrases, pasted private keys,
///    and the vault master secret) are stored in the OS Keyring via the Linux Secret Service API
///    (`libsecret` / GNOME Keyring) under schema `org.openoia.CredentialVault`.
/// 2. No plaintext passwords or private keys are ever stored in `settings.json` or `ssh_hosts.json`.
/// 3. All local files (`settings.json`, `ssh_hosts.json`, `ssh_snippets.json`, `history.json`,
///    imported `.ovpn` profiles, and converted `.pem` keys) are encrypted at rest using
///    AES-256-CTR + HMAC-SHA256 (Encrypt-then-MAC) with keys derived via PBKDF2-HMAC-SHA256.
class SecureStorageVault {
  final Directory configDir;
  late final File _masterKeyFile;
  late final File _fallbackSecretsFile;
  Uint8List? _cachedMasterSecret;
  final Map<String, String> _secretMemoryCache = {};

  SecureStorageVault(this.configDir) {
    _masterKeyFile = File('${configDir.path}/.master.key');
    _fallbackSecretsFile = File('${configDir.path}/.secrets.enc');
  }

  Map<String, String> _cleanEnv() {
    return Map<String, String>.from(Platform.environment)
      ..remove('LD_LIBRARY_PATH')
      ..remove('PYTHONHOME')
      ..remove('PYTHONPATH');
  }

  /// Stores a secret in Linux Secret Service (libsecret / GNOME Keyring)
  /// and in the encrypted local vault fallback.
  void setSecret(String key, String value) {
    _secretMemoryCache[key] = value;

    // 1. Store in Linux Secret Service (libsecret / GNOME Keyring)
    try {
      final env = _cleanEnv();
      env['OPENOIA_SEC_KEY'] = key;
      env['OPENOIA_SEC_VAL'] = value;
      Process.runSync(
        'python3',
        ['-c', _pyKeyringStore],
        environment: env,
      );
    } catch (_) {}

    // 2. Also update encrypted fallback store (.secrets.enc) with AES-256-CTR + HMAC-SHA256
    try {
      final map = _readFallbackSecretsMap();
      if (value.isEmpty) {
        map.remove(key);
      } else {
        map[key] = value;
      }
      writeEncryptedJson(_fallbackSecretsFile, map);
    } catch (_) {}
  }

  /// Retrieves a secret from Linux Secret Service (libsecret / GNOME Keyring)
  /// or from the encrypted fallback vault.
  String getSecret(String key) {
    if (_secretMemoryCache.containsKey(key)) {
      return _secretMemoryCache[key]!;
    }

    // 1. Lookup in Linux Secret Service (libsecret / GNOME Keyring)
    try {
      final env = _cleanEnv();
      env['OPENOIA_SEC_KEY'] = key;
      final res = Process.runSync(
        'python3',
        ['-c', _pyKeyringLookup],
        environment: env,
      );
      if (res.exitCode == 0) {
        final out = res.stdout.toString();
        if (out.startsWith('FOUND:')) {
          final val = out.substring(6);
          _secretMemoryCache[key] = val;
          return val;
        }
      }
    } catch (_) {}

    // 2. Fallback to encrypted local vault (.secrets.enc)
    try {
      final map = _readFallbackSecretsMap();
      final val = map[key]?.toString() ?? '';
      if (val.isNotEmpty) {
        _secretMemoryCache[key] = val;
        // Opportunistically sync into OS Keyring
        setSecret(key, val);
      }
      return val;
    } catch (_) {
      return '';
    }
  }

  /// Deletes a secret from Linux Secret Service (libsecret / GNOME Keyring) and fallback vault.
  void deleteSecret(String key) {
    _secretMemoryCache.remove(key);
    try {
      final env = _cleanEnv();
      env['OPENOIA_SEC_KEY'] = key;
      Process.runSync(
        'python3',
        ['-c', _pyKeyringDelete],
        environment: env,
      );
    } catch (_) {}
    try {
      final map = _readFallbackSecretsMap();
      if (map.remove(key) != null) {
        writeEncryptedJson(_fallbackSecretsFile, map);
      }
    } catch (_) {}
  }

  Map<String, dynamic> _readFallbackSecretsMap() {
    if (!_fallbackSecretsFile.existsSync()) return <String, dynamic>{};
    final decoded = readEncryptedJson(_fallbackSecretsFile);
    if (decoded is Map<String, dynamic>) {
      return Map<String, dynamic>.from(decoded);
    }
    return <String, dynamic>{};
  }

  Uint8List _getMasterSecret() {
    if (_cachedMasterSecret != null) return _cachedMasterSecret!;

    try {
      if (!configDir.existsSync()) {
        configDir.createSync(recursive: true);
      }
      Process.runSync('chmod', ['700', configDir.path]);
    } catch (_) {}

    Uint8List? rawKeyBytes;

    // Try reading master key from Linux Secret Service (libsecret) first
    try {
      final env = _cleanEnv();
      env['OPENOIA_SEC_KEY'] = '__vault_master_key__';
      final res = Process.runSync(
        'python3',
        ['-c', _pyKeyringLookup],
        environment: env,
      );
      if (res.exitCode == 0) {
        final out = res.stdout.toString();
        if (out.startsWith('FOUND:')) {
          final b64 = out.substring(6).trim();
          final decoded = base64Decode(b64);
          if (decoded.length >= 32) {
            rawKeyBytes = decoded;
          }
        }
      }
    } catch (_) {}

    if (rawKeyBytes == null && _masterKeyFile.existsSync()) {
      try {
        final b64 = _masterKeyFile.readAsStringSync().trim();
        final decoded = base64Decode(b64);
        if (decoded.length >= 32) {
          rawKeyBytes = decoded;
          // Migrate master key into Linux Secret Service (libsecret)
          final env = _cleanEnv();
          env['OPENOIA_SEC_KEY'] = '__vault_master_key__';
          env['OPENOIA_SEC_VAL'] = b64;
          Process.runSync('python3', ['-c', _pyKeyringStore], environment: env);
        }
      } catch (_) {}
    }

    rawKeyBytes ??= _generateAndSaveMasterKey();

    // Bind master key with Linux machine-id and OS user
    String machineId = 'openoia-linux-vault';
    try {
      final midFile = File('/etc/machine-id');
      if (midFile.existsSync()) {
        machineId = midFile.readAsStringSync().trim();
      }
    } catch (_) {}
    final user = Platform.environment['USER'] ?? 'linux-user';
    final bindingBytes = utf8.encode('$machineId:$user:openoia-v2');

    final combined = Uint8List(rawKeyBytes.length + bindingBytes.length);
    combined.setRange(0, rawKeyBytes.length, rawKeyBytes);
    combined.setRange(rawKeyBytes.length, combined.length, bindingBytes);

    _cachedMasterSecret = _Sha256.hash(combined);
    return _cachedMasterSecret!;
  }

  Uint8List _generateAndSaveMasterKey() {
    final rng = Random.secure();
    final bytes = Uint8List.fromList(
      List<int>.generate(32, (_) => rng.nextInt(256)),
    );
    final b64 = base64Encode(bytes);
    try {
      _masterKeyFile.writeAsStringSync(b64);
      Process.runSync('chmod', ['600', _masterKeyFile.path]);
    } catch (_) {}
    try {
      final env = _cleanEnv();
      env['OPENOIA_SEC_KEY'] = '__vault_master_key__';
      env['OPENOIA_SEC_VAL'] = b64;
      Process.runSync('python3', ['-c', _pyKeyringStore], environment: env);
    } catch (_) {}
    return bytes;
  }

  /// Encrypts arbitrary UTF-8 string into an authenticated JSON envelope
  String encryptString(String plaintext) {
    final rng = Random.secure();
    final salt = Uint8List.fromList(
      List<int>.generate(16, (_) => rng.nextInt(256)),
    );
    final iv = Uint8List.fromList(
      List<int>.generate(16, (_) => rng.nextInt(256)),
    );

    final master = _getMasterSecret();
    final derived = _Pbkdf2.deriveKey(
      password: master,
      salt: salt,
      iterations: 10000,
      dkLen: 64,
    );
    final aesKey = Uint8List.sublistView(derived, 0, 32);
    final macKey = Uint8List.sublistView(derived, 32, 64);

    final plainBytes = Uint8List.fromList(utf8.encode(plaintext));
    final cipherBytes = _Aes256Ctr.transform(plainBytes, aesKey, iv);

    final macInput = Uint8List(salt.length + iv.length + cipherBytes.length);
    macInput.setRange(0, salt.length, salt);
    macInput.setRange(salt.length, salt.length + iv.length, iv);
    macInput.setRange(salt.length + iv.length, macInput.length, cipherBytes);
    final mac = _HmacSha256.compute(macKey, macInput);

    final envelope = <String, dynamic>{
      '__encrypted__': true,
      'version': 2,
      'cipher': 'AES-256-CTR-HMAC-SHA256',
      'kdf': 'PBKDF2-HMAC-SHA256',
      'salt': base64Encode(salt),
      'iv': base64Encode(iv),
      'mac': base64Encode(mac),
      'ciphertext': base64Encode(cipherBytes),
    };
    return const JsonEncoder.withIndent('  ').convert(envelope);
  }

  /// Decrypts an authenticated JSON envelope back into plaintext UTF-8 string
  String? decryptString(String rawContent) {
    try {
      final decoded = jsonDecode(rawContent);
      if (decoded is Map<String, dynamic> && decoded['__encrypted__'] == true) {
        final salt = base64Decode(decoded['salt'].toString());
        final iv = base64Decode(decoded['iv'].toString());
        final expectedMac = base64Decode(decoded['mac'].toString());
        final cipherBytes = base64Decode(decoded['ciphertext'].toString());

        final master = _getMasterSecret();
        final derived = _Pbkdf2.deriveKey(
          password: master,
          salt: salt,
          iterations: 10000,
          dkLen: 64,
        );
        final aesKey = Uint8List.sublistView(derived, 0, 32);
        final macKey = Uint8List.sublistView(derived, 32, 64);

        final macInput =
            Uint8List(salt.length + iv.length + cipherBytes.length);
        macInput.setRange(0, salt.length, salt);
        macInput.setRange(salt.length, salt.length + iv.length, iv);
        macInput.setRange(
            salt.length + iv.length, macInput.length, cipherBytes);
        final actualMac = _HmacSha256.compute(macKey, macInput);

        if (!_constantTimeEquals(expectedMac, actualMac)) {
          return null;
        }

        final plainBytes = _Aes256Ctr.transform(cipherBytes, aesKey, iv);
        return utf8.decode(plainBytes);
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Writes arbitrary text encrypted on disk with chmod 600
  void writeEncryptedTextFile(File file, String content) {
    try {
      final encryptedEnvelope = encryptString(content);
      file.writeAsStringSync(encryptedEnvelope);
      Process.runSync('chmod', ['600', file.path]);
    } catch (_) {}
  }

  /// Reads and decrypts an encrypted text file (migrating plaintext if needed)
  String? readEncryptedTextFile(File file) {
    if (!file.existsSync()) return null;
    try {
      final raw = file.readAsStringSync();
      if (raw.trim().isEmpty) return '';
      final decrypted = decryptString(raw);
      if (decrypted != null) return decrypted;

      // Migrate legacy plaintext file to encrypted format on disk
      writeEncryptedTextFile(file, raw);
      return raw;
    } catch (_) {
      return null;
    }
  }

  /// Saves any JSON-serializable object (Map or List) encrypted on disk with chmod 600
  void writeEncryptedJson(File file, Object data) {
    try {
      final jsonStr = jsonEncode(data);
      final encryptedEnvelope = encryptString(jsonStr);
      file.writeAsStringSync(encryptedEnvelope);
      Process.runSync('chmod', ['600', file.path]);
    } catch (_) {}
  }

  /// Reads and decrypts a JSON file. If the file is still in legacy plaintext JSON,
  /// transparently migrates it to encrypted format on disk and returns the parsed JSON.
  dynamic readEncryptedJson(File file) {
    if (!file.existsSync()) return null;
    try {
      final raw = file.readAsStringSync().trim();
      if (raw.isEmpty) return null;

      final parsedOuter = jsonDecode(raw);
      if (parsedOuter is Map<String, dynamic> &&
          parsedOuter['__encrypted__'] == true) {
        final decryptedStr = decryptString(raw);
        if (decryptedStr == null) return null;
        return jsonDecode(decryptedStr);
      }

      // Legacy plaintext JSON detected: automatically encrypt it on disk now
      writeEncryptedJson(file, parsedOuter);
      return parsedOuter;
    } catch (_) {
      return null;
    }
  }

  bool _constantTimeEquals(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    int diff = 0;
    for (int i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  static const String _pyKeyringStore = r'''
import os, sys
try:
    import gi
    gi.require_version('Secret', '1')
    from gi.repository import Secret
    schema = Secret.Schema.new(
        "org.openoia.CredentialVault",
        Secret.SchemaFlags.NONE,
        {"application": Secret.SchemaAttributeType.STRING, "key": Secret.SchemaAttributeType.STRING}
    )
    k = os.environ.get("OPENOIA_SEC_KEY", "")
    v = os.environ.get("OPENOIA_SEC_VAL", "")
    if v:
        Secret.password_store_sync(
            schema,
            {"application": "openoia", "key": k},
            Secret.COLLECTION_DEFAULT,
            f"Openoia: {k}",
            v,
            None
        )
    else:
        Secret.password_clear_sync(schema, {"application": "openoia", "key": k}, None)
except Exception:
    sys.exit(1)
''';

  static const String _pyKeyringLookup = r'''
import os, sys
try:
    import gi
    gi.require_version('Secret', '1')
    from gi.repository import Secret
    schema = Secret.Schema.new(
        "org.openoia.CredentialVault",
        Secret.SchemaFlags.NONE,
        {"application": Secret.SchemaAttributeType.STRING, "key": Secret.SchemaAttributeType.STRING}
    )
    k = os.environ.get("OPENOIA_SEC_KEY", "")
    pw = Secret.password_lookup_sync(schema, {"application": "openoia", "key": k}, None)
    if pw is not None:
        sys.stdout.write("FOUND:" + pw)
        sys.exit(0)
    sys.exit(1)
except Exception:
    sys.exit(1)
''';

  static const String _pyKeyringDelete = r'''
import os, sys
try:
    import gi
    gi.require_version('Secret', '1')
    from gi.repository import Secret
    schema = Secret.Schema.new(
        "org.openoia.CredentialVault",
        Secret.SchemaFlags.NONE,
        {"application": Secret.SchemaAttributeType.STRING, "key": Secret.SchemaAttributeType.STRING}
    )
    k = os.environ.get("OPENOIA_SEC_KEY", "")
    Secret.password_clear_sync(schema, {"application": "openoia", "key": k}, None)
except Exception:
    sys.exit(1)
''';
}

// ============================================================================
// Pure-Dart Cryptographic Primitives:
// - SHA-256 (FIPS 180-4)
// - HMAC-SHA256 (RFC 2104)
// - PBKDF2-HMAC-SHA256 (RFC 2898)
// - AES-256-CTR (FIPS 197 + NIST SP 800-38A)
// ============================================================================

class _Sha256 {
  static const List<int> _k = [
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
    0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
    0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
    0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
    0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
    0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
  ];

  static int _rotr(int x, int n) => ((x >>> n) | (x << (32 - n))) & 0xFFFFFFFF;

  static Uint8List hash(Uint8List message) {
    int h0 = 0x6a09e667;
    int h1 = 0xbb67ae85;
    int h2 = 0x3c6ef372;
    int h3 = 0xa54ff53a;
    int h4 = 0x510e527f;
    int h5 = 0x9b05688c;
    int h6 = 0x1f83d9ab;
    int h7 = 0x5be0cd19;

    final bitLen = message.length * 8;
    final padLen = ((55 - message.length) % 64 + 64) % 64;
    final totalLen = message.length + 1 + padLen + 8;
    final padded = Uint8List(totalLen);
    padded.setRange(0, message.length, message);
    padded[message.length] = 0x80;

    final bd = ByteData.sublistView(padded);
    bd.setUint32(totalLen - 8, (bitLen ~/ 0x100000000) & 0xFFFFFFFF, Endian.big);
    bd.setUint32(totalLen - 4, bitLen & 0xFFFFFFFF, Endian.big);

    final w = Uint32List(64);
    for (int offset = 0; offset < totalLen; offset += 64) {
      for (int i = 0; i < 16; i++) {
        w[i] = bd.getUint32(offset + i * 4, Endian.big);
      }
      for (int i = 16; i < 64; i++) {
        final s0 = _rotr(w[i - 15], 7) ^ _rotr(w[i - 15], 18) ^ (w[i - 15] >>> 3);
        final s1 = _rotr(w[i - 2], 17) ^ _rotr(w[i - 2], 19) ^ (w[i - 2] >>> 10);
        w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & 0xFFFFFFFF;
      }

      int a = h0, b = h1, c = h2, d = h3, e = h4, f = h5, g = h6, h = h7;

      for (int i = 0; i < 64; i++) {
        final s1 = _rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25);
        final ch = (e & f) ^ ((~e & 0xFFFFFFFF) & g);
        final temp1 = (h + s1 + ch + _k[i] + w[i]) & 0xFFFFFFFF;
        final s0 = _rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22);
        final maj = (a & b) ^ (a & c) ^ (b & c);
        final temp2 = (s0 + maj) & 0xFFFFFFFF;

        h = g;
        g = f;
        f = e;
        e = (d + temp1) & 0xFFFFFFFF;
        d = c;
        c = b;
        b = a;
        a = (temp1 + temp2) & 0xFFFFFFFF;
      }

      h0 = (h0 + a) & 0xFFFFFFFF;
      h1 = (h1 + b) & 0xFFFFFFFF;
      h2 = (h2 + c) & 0xFFFFFFFF;
      h3 = (h3 + d) & 0xFFFFFFFF;
      h4 = (h4 + e) & 0xFFFFFFFF;
      h5 = (h5 + f) & 0xFFFFFFFF;
      h6 = (h6 + g) & 0xFFFFFFFF;
      h7 = (h7 + h) & 0xFFFFFFFF;
    }

    final out = Uint8List(32);
    final outBd = ByteData.sublistView(out);
    outBd.setUint32(0, h0, Endian.big);
    outBd.setUint32(4, h1, Endian.big);
    outBd.setUint32(8, h2, Endian.big);
    outBd.setUint32(12, h3, Endian.big);
    outBd.setUint32(16, h4, Endian.big);
    outBd.setUint32(20, h5, Endian.big);
    outBd.setUint32(24, h6, Endian.big);
    outBd.setUint32(28, h7, Endian.big);
    return out;
  }
}

class _HmacSha256 {
  static Uint8List compute(Uint8List key, Uint8List data) {
    Uint8List k = key;
    if (k.length > 64) {
      k = _Sha256.hash(k);
    }
    final keyBlock = Uint8List(64);
    keyBlock.setRange(0, k.length, k);

    final oKeyPad = Uint8List(64);
    final iKeyPad = Uint8List(64);
    for (int i = 0; i < 64; i++) {
      oKeyPad[i] = keyBlock[i] ^ 0x5c;
      iKeyPad[i] = keyBlock[i] ^ 0x36;
    }

    final innerInput = Uint8List(64 + data.length);
    innerInput.setRange(0, 64, iKeyPad);
    innerInput.setRange(64, innerInput.length, data);
    final innerHash = _Sha256.hash(innerInput);

    final outerInput = Uint8List(64 + 32);
    outerInput.setRange(0, 64, oKeyPad);
    outerInput.setRange(64, 96, innerHash);
    return _Sha256.hash(outerInput);
  }
}

class _Pbkdf2 {
  static Uint8List deriveKey({
    required Uint8List password,
    required Uint8List salt,
    required int iterations,
    required int dkLen,
  }) {
    final blocks = (dkLen + 31) ~/ 32;
    final out = Uint8List(blocks * 32);

    for (int block = 1; block <= blocks; block++) {
      final saltBlock = Uint8List(salt.length + 4);
      saltBlock.setRange(0, salt.length, salt);
      saltBlock[salt.length] = (block >>> 24) & 0xFF;
      saltBlock[salt.length + 1] = (block >>> 16) & 0xFF;
      saltBlock[salt.length + 2] = (block >>> 8) & 0xFF;
      saltBlock[salt.length + 3] = block & 0xFF;

      Uint8List u = _HmacSha256.compute(password, saltBlock);
      final t = Uint8List.fromList(u);

      for (int i = 1; i < iterations; i++) {
        u = _HmacSha256.compute(password, u);
        for (int j = 0; j < 32; j++) {
          t[j] ^= u[j];
        }
      }
      out.setRange((block - 1) * 32, block * 32, t);
    }

    return Uint8List.sublistView(out, 0, dkLen);
  }
}

class _Aes256Ctr {
  static const List<int> _sbox = [
    0x63, 0x7c, 0x77, 0x7b, 0xf2, 0x6b, 0x6f, 0xc5, 0x30, 0x01, 0x67, 0x2b, 0xfe, 0xd7, 0xab, 0x76,
    0xca, 0x82, 0xc9, 0x7d, 0xfa, 0x59, 0x47, 0xf0, 0xad, 0xd4, 0xa2, 0xaf, 0x9c, 0xa4, 0x72, 0xc0,
    0xb7, 0xfd, 0x93, 0x26, 0x36, 0x3f, 0xf7, 0xcc, 0x34, 0xa5, 0xe5, 0xf1, 0x71, 0xd8, 0x31, 0x15,
    0x04, 0xc7, 0x23, 0xc3, 0x18, 0x96, 0x05, 0x9a, 0x07, 0x12, 0x80, 0xe2, 0xeb, 0x27, 0xb2, 0x75,
    0x09, 0x83, 0x2c, 0x1a, 0x1b, 0x6e, 0x5a, 0xa0, 0x52, 0x3b, 0xd6, 0xb3, 0x29, 0xe3, 0x2f, 0x84,
    0x53, 0xd1, 0x00, 0xed, 0x20, 0xfc, 0xb1, 0x5b, 0x6a, 0xcb, 0xbe, 0x39, 0x4a, 0x4c, 0x58, 0xcf,
    0xd0, 0xef, 0xaa, 0xfb, 0x43, 0x4d, 0x33, 0x85, 0x45, 0xf9, 0x02, 0x7f, 0x50, 0x3c, 0x9f, 0xa8,
    0x51, 0xa3, 0x40, 0x8f, 0x92, 0x9d, 0x38, 0xf5, 0xbc, 0xb6, 0xda, 0x21, 0x10, 0xff, 0xf3, 0xd2,
    0xcd, 0x0c, 0x13, 0xec, 0x5f, 0x97, 0x44, 0x17, 0xc4, 0xa7, 0x7e, 0x3d, 0x64, 0x5d, 0x19, 0x73,
    0x60, 0x81, 0x4f, 0xdc, 0x22, 0x2a, 0x90, 0x88, 0x46, 0xee, 0xb8, 0x14, 0xde, 0x5e, 0x0b, 0xdb,
    0xe0, 0x32, 0x3a, 0x0a, 0x49, 0x06, 0x24, 0x5c, 0xc2, 0xd3, 0xac, 0x62, 0x91, 0x95, 0xe4, 0x79,
    0xe7, 0xc8, 0x37, 0x6d, 0x8d, 0xd5, 0x4e, 0xa9, 0x6c, 0x56, 0xf4, 0xea, 0x65, 0x7a, 0xae, 0x08,
    0xba, 0x78, 0x25, 0x2e, 0x1c, 0xa6, 0xb4, 0xc6, 0xe8, 0xdd, 0x74, 0x1f, 0x4b, 0xbd, 0x8b, 0x8a,
    0x70, 0x3e, 0xb5, 0x66, 0x48, 0x03, 0xf6, 0x0e, 0x61, 0x35, 0x57, 0xb9, 0x86, 0xc1, 0x1d, 0x9e,
    0xe1, 0xf8, 0x98, 0x11, 0x69, 0xd9, 0x8e, 0x94, 0x9b, 0x1e, 0x87, 0xe9, 0xce, 0x55, 0x28, 0xdf,
    0x8c, 0xa1, 0x89, 0x0d, 0xbf, 0xe6, 0x42, 0x68, 0x41, 0x99, 0x2d, 0x0f, 0xb0, 0x54, 0xbb, 0x16,
  ];

  static const List<int> _rcon = [
    0x00, 0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1b, 0x36,
  ];

  static int _xtime(int a) => ((a << 1) ^ (((a >> 7) & 1) * 0x1b)) & 0xFF;

  static Uint8List _expandKey256(Uint8List key) {
    final roundKeys = Uint8List(240);
    roundKeys.setRange(0, 32, key);

    final temp = Uint8List(4);
    int bytesGenerated = 32;
    int rconIteration = 1;

    while (bytesGenerated < 240) {
      for (int i = 0; i < 4; i++) {
        temp[i] = roundKeys[bytesGenerated - 4 + i];
      }

      if (bytesGenerated % 32 == 0) {
        final t = temp[0];
        temp[0] = _sbox[temp[1]] ^ _rcon[rconIteration++];
        temp[1] = _sbox[temp[2]];
        temp[2] = _sbox[temp[3]];
        temp[3] = _sbox[t];
      } else if (bytesGenerated % 32 == 16) {
        for (int i = 0; i < 4; i++) {
          temp[i] = _sbox[temp[i]];
        }
      }

      for (int i = 0; i < 4; i++) {
        roundKeys[bytesGenerated] = roundKeys[bytesGenerated - 32] ^ temp[i];
        bytesGenerated++;
      }
    }
    return roundKeys;
  }

  static Uint8List _encryptBlock(Uint8List input, Uint8List roundKeys) {
    final s = Uint8List.fromList(input);

    for (int i = 0; i < 16; i++) {
      s[i] ^= roundKeys[i];
    }

    for (int round = 1; round <= 14; round++) {
      for (int i = 0; i < 16; i++) {
        s[i] = _sbox[s[i]];
      }

      int t = s[1];
      s[1] = s[5];
      s[5] = s[9];
      s[9] = s[13];
      s[13] = t;

      t = s[2];
      s[2] = s[10];
      s[10] = t;
      t = s[6];
      s[6] = s[14];
      s[14] = t;

      t = s[15];
      s[15] = s[11];
      s[11] = s[7];
      s[7] = s[3];
      s[3] = t;

      if (round < 14) {
        for (int c = 0; c < 16; c += 4) {
          final a0 = s[c], a1 = s[c + 1], a2 = s[c + 2], a3 = s[c + 3];
          final tm = a0 ^ a1 ^ a2 ^ a3;
          s[c] ^= tm ^ _xtime(a0 ^ a1);
          s[c + 1] ^= tm ^ _xtime(a1 ^ a2);
          s[c + 2] ^= tm ^ _xtime(a2 ^ a3);
          s[c + 3] ^= tm ^ _xtime(a3 ^ a0);
        }
      }

      final rkOffset = round * 16;
      for (int i = 0; i < 16; i++) {
        s[i] ^= roundKeys[rkOffset + i];
      }
    }

    return s;
  }

  static Uint8List transform(Uint8List data, Uint8List key, Uint8List iv) {
    final roundKeys = _expandKey256(key);
    final counter = Uint8List.fromList(iv);
    final output = Uint8List(data.length);

    for (int offset = 0; offset < data.length; offset += 16) {
      final keystream = _encryptBlock(counter, roundKeys);
      final blockLen =
          (offset + 16 <= data.length) ? 16 : (data.length - offset);
      for (int i = 0; i < blockLen; i++) {
        output[offset + i] = data[offset + i] ^ keystream[i];
      }

      for (int i = 15; i >= 0; i--) {
        counter[i] = (counter[i] + 1) & 0xFF;
        if (counter[i] != 0) break;
      }
    }
    return output;
  }
}
