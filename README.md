# Openoia

Cliente Desktop Linux moderno desenvolvido em **Flutter (GTK3)** que integra:

- **Cliente OpenVPN**:
  - Conexão rápida via perfis `.ovpn` (perfis nunca são embutidos no AppImage; o perfil selecionado pelo usuário é criptografado localmente no cofre `vpn_profile.ovpn.enc`)
  - **Root Helper Hardened (`/usr/local/bin/vpn-openoia-root-helper`)**: sanitiza diretivas do perfil `.ovpn`, grava apenas em diretório protegido de propriedade do `root` (`/etc/openvpn/client/openoia/active.conf`, `0600`), força `--script-security 0` e nunca aceita exclusão de caminhos arbitrários
  - Monitoramento de IP atribuído (`tun`), tempo de sessão, histórico persistente e logs criptografados
- **Gerenciamento Seguro de Credenciais & Criptografia Total**:
  - Integração nativa com a API **Linux Secret Service (`libsecret` / GNOME Keyring)** sob o schema `org.openoia.CredentialVault` para armazenar senhas da VPN, senhas SSH, passphrases e chaves privadas fora de `settings.json` e `ssh_hosts.json`
  - Todos os arquivos locais em `~/.config/vpn-openoia/` são criptografados em repouso com **AES-256-CTR + HMAC-SHA256 (Encrypt-then-MAC)** e derivação **PBKDF2-HMAC-SHA256**
- **Workspace SSH & SFTP**:
  - Gerenciador de múltiplos servidores SSH/SFTP agrupados por ambiente
  - Suporte a autenticação via **Password**, **SSH ID (Passkeys for SSH)**, **Key (`.pem`, `.ppk`, `id_rsa`, `id_ed25519`)**, **Certificate (`*-cert.pub`)** e **FIDO2 (`SecurityKeyProvider`)**
  - Conversão automática de chaves PuTTY (`.ppk`, inclusive criptografadas) para OpenSSH com armazenamento criptografado (`.pem.enc`)
  - **Protocolo SFTP Nativo (`sftp -b`)**: listagem, criação de pastas, exclusão e transferência de arquivos via subsistema SFTP puro, sem invocação de shell remoto (`bash -c` / `rm -rf`) e imune a injeção de comandos
  - Terminal interativo (`xterm` + PTY) com painel de **Snippets** moderno e retrátil
- **Integração com Ubuntu Top Bar (System Tray / AppIndicator)**:
  - Minimiza para a Top Bar ao fechar a janela (`X`)
  - Indicador visual com bolinha verde quando conectado
  - Duplo clique no ícone da Top Bar restaura a janela e menu de contexto (`Abrir Openoia` / `Sair`) desconecta a VPN com segurança ao encerrar

## Compilação (AppImage)

```bash
./build_appimage.sh
```
