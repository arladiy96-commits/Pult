#!/usr/bin/env python3
"""Optional diagnostics from a computer in the SAME LAN.

Before sending any PIN/token, compare the TV's SHA-256 certificate fingerprint.
Examples:
  python3 scripts/test_client.py 192.168.1.50 --fingerprint AA:BB:... --pin 123456
  python3 scripts/test_client.py 192.168.1.50 --fingerprint AA:BB:... --token '...' --cmd apps
  python3 scripts/test_client.py 192.168.1.50 --fingerprint AA:BB:... --token '...' --cmd move --dx 80 --dy 40
"""
import argparse
import hashlib
import json
import socket
import ssl


def main():
    p = argparse.ArgumentParser()
    p.add_argument('host')
    p.add_argument('--port', type=int, default=39678)
    p.add_argument('--fingerprint', required=True, help='SHA-256 cert hex, shown by TV')
    auth = p.add_mutually_exclusive_group(required=True)
    auth.add_argument('--pin')
    auth.add_argument('--token')
    p.add_argument('--cmd', default='ping', choices=['ping', 'apps', 'move', 'tap', 'scroll', 'text', 'launch', 'delete', 'key'])
    p.add_argument('--dx', type=float, default=0)
    p.add_argument('--dy', type=float, default=1)
    p.add_argument('--text', default='Привет с телефона')
    p.add_argument('--package', default='')
    p.add_argument('--code', type=int, default=4)
    a = p.parse_args()

    expected = a.fingerprint.replace(':', '').replace(' ', '').lower()
    if len(expected) != 64 or any(c not in '0123456789abcdef' for c in expected):
        p.error('Введите ПОЛНЫЙ SHA-256 сертификата из экрана приставки')
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE  # TOFU with mandatory explicit fingerprint check below.
    with socket.create_connection((a.host, a.port), timeout=6) as raw:
        with ctx.wrap_socket(raw, server_hostname=a.host) as conn:
            observed = hashlib.sha256(conn.getpeercert(binary_form=True)).hexdigest()
            if observed != expected:
                raise RuntimeError('ОТПЕЧАТОК НЕ СОВПАДАЕТ! Соединение закрыто до отправки кода.')
            print('TLS certificate verified against TV fingerprint')
            conn.settimeout(10)
            stream = conn.makefile('rwb')

            def send(msg):
                stream.write((json.dumps(msg, ensure_ascii=False) + '\n').encode('utf-8'))
                stream.flush()
                line = stream.readline()
                if not line:
                    raise RuntimeError('Приставка закрыла соединение')
                return json.loads(line)

            if a.pin:
                answer = send({'cmd': 'pair', 'pin': a.pin})
                print(json.dumps(answer, ensure_ascii=False, indent=2))
                print('СОХРАНИТЕ TOKEN В БЕЗОПАСНОМ МЕСТЕ; код одноразовый.')
                return
            login = send({'cmd': 'auth', 'token': a.token})
            if not login.get('ok'):
                print(login)
                return
            command = {'cmd': a.cmd}
            if a.cmd in ('move', 'scroll'):
                command.update(dx=a.dx, dy=a.dy)
            if a.cmd == 'text':
                command['text'] = a.text
            if a.cmd == 'launch':
                command['package'] = a.package
            if a.cmd == 'key':
                command['code'] = a.code
            result = send(command)
            if a.cmd == 'apps' and result.get('ok'):
                result['apps'] = [{'name': e['name'], 'package': e['package']} for e in result['apps']]
            print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
