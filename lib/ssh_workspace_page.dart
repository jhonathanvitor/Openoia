import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';
import 'secure_storage.dart';
import 'ssh_models.dart';

enum WorkspaceTabType { terminal, sftp }

/// Crisp vector "Sidebar Left" / "Sidebar Right" icon drawn directly on canvas
class SidebarToggleIcon extends StatelessWidget {
  final bool isLeft;
  final bool isOpen;
  final Color color;
  final double size;

  const SidebarToggleIcon({
    super.key,
    required this.isLeft,
    this.isOpen = true,
    required this.color,
    this.size = 18,
  });

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size(size, size * 0.84),
      painter: _SidebarTogglePainter(
        isLeft: isLeft,
        isOpen: isOpen,
        color: color,
      ),
    );
  }
}

class _SidebarTogglePainter extends CustomPainter {
  final bool isLeft;
  final bool isOpen;
  final Color color;

  _SidebarTogglePainter({
    required this.isLeft,
    required this.isOpen,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final strokePaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final fillPaint = Paint()
      ..color = color.withValues(alpha: isOpen ? 0.25 : 0.08)
      ..style = PaintingStyle.fill;

    final outerRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(0.8, 0.8, size.width - 1.6, size.height - 1.6),
      const Radius.circular(3.2),
    );

    final splitX = isLeft ? size.width * 0.36 : size.width * 0.64;

    // Fill the sidebar pane
    canvas.save();
    canvas.clipRRect(outerRect);
    if (isLeft) {
      canvas.drawRect(Rect.fromLTWH(0, 0, splitX, size.height), fillPaint);
    } else {
      canvas.drawRect(
        Rect.fromLTWH(splitX, 0, size.width - splitX, size.height),
        fillPaint,
      );
    }
    canvas.restore();

    // Draw outer rounded frame
    canvas.drawRRect(outerRect, strokePaint);

    // Draw vertical divider between sidebar and main area
    canvas.drawLine(
      Offset(splitX, 1.0),
      Offset(splitX, size.height - 1.0),
      strokePaint,
    );

    // Draw 2 tiny horizontal item bars inside sidebar pane
    final barPaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.3
      ..strokeCap = StrokeCap.round;

    final barStartX = isLeft ? 2.8 : splitX + 2.2;
    final barEndX = isLeft ? splitX - 2.2 : size.width - 2.8;
    if (barEndX > barStartX) {
      canvas.drawLine(
        Offset(barStartX, size.height * 0.36),
        Offset(barEndX, size.height * 0.36),
        barPaint,
      );
      canvas.drawLine(
        Offset(barStartX, size.height * 0.60),
        Offset(barEndX, size.height * 0.60),
        barPaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _SidebarTogglePainter oldDelegate) {
    return oldDelegate.isLeft != isLeft ||
        oldDelegate.isOpen != isOpen ||
        oldDelegate.color != color;
  }
}

class WorkspaceSessionTab {
  final String tabId;
  final SshHostConfig host;
  final WorkspaceTabType type;
  final String? initialDirectory;

  WorkspaceSessionTab({
    required this.tabId,
    required this.host,
    required this.type,
    this.initialDirectory,
  });
}

class SshWorkspacePage extends StatefulWidget {
  final bool isDark;
  final Directory configDir;

  const SshWorkspacePage({
    super.key,
    required this.isDark,
    required this.configDir,
  });

  @override
  State<SshWorkspacePage> createState() => _SshWorkspacePageState();
}

class _SshWorkspacePageState extends State<SshWorkspacePage> {
  late final SecureStorageVault _vault;
  late final File _hostsFile;
  late final File _snippetsFile;
  late final SshHelperManager _sshHelper;

  final List<SshHostConfig> _hosts = [];
  final List<SshSnippet> _snippets = [];
  final List<WorkspaceSessionTab> _openTabs = [];
  int _activeTabIndex = 0;
  String _searchQuery = '';
  bool _isSidebarVisible = true;

  @override
  void initState() {
    super.initState();
    _vault = SecureStorageVault(widget.configDir);
    _hostsFile = File('${widget.configDir.path}/ssh_hosts.json');
    _snippetsFile = File('${widget.configDir.path}/ssh_snippets.json');
    _sshHelper = SshHelperManager(widget.configDir);
    _loadHosts();
    _loadSnippets();
  }

  void _loadHosts() {
    if (_hostsFile.existsSync()) {
      try {
        final list = _vault.readEncryptedJson(_hostsFile);
        if (list is List) {
          _hosts.clear();
          bool hadInlineSecrets = false;
          for (final item in list) {
            if (item is Map<String, dynamic>) {
              if (item.containsKey('password') ||
                  item.containsKey('passphrase') ||
                  item.containsKey('privateKeyContent')) {
                hadInlineSecrets = true;
              }
              _hosts.add(SshHostConfig.fromJson(item, vault: _vault));
            }
          }
          if (hadInlineSecrets) {
            // Re-save ssh_hosts.json stripped of inline secrets (stored in Linux Secret Service)
            _saveHosts();
          }
          setState(() {});
        }
      } catch (_) {}
    }
  }

  void _saveHosts() {
    for (final h in _hosts) {
      h.saveSecretsToVault(_vault);
    }
    final list = _hosts.map((h) => h.toJson()).toList();
    _vault.writeEncryptedJson(_hostsFile, list);
  }

  void _loadSnippets() {
    if (_snippetsFile.existsSync()) {
      try {
        final list = _vault.readEncryptedJson(_snippetsFile);
        if (list is List) {
          _snippets.clear();
          for (final item in list) {
            if (item is Map<String, dynamic>) {
              _snippets.add(SshSnippet.fromJson(item));
            }
          }
          setState(() {});
          return;
        }
      } catch (_) {}
    }
    // Default helpful snippets on first run
    _snippets.addAll([
      SshSnippet(
        id: 'default_1',
        title: 'Uso de Disco e Memória',
        category: 'Sistema',
        command: 'df -h && free -h',
      ),
      SshSnippet(
        id: 'default_2',
        title: 'Listar Processos / Containers Docker',
        category: 'Docker',
        command: 'docker ps -a',
      ),
      SshSnippet(
        id: 'default_3',
        title: 'Status Git & Último Commit',
        category: 'Deploy',
        command: 'git status && git log -n 1',
      ),
    ]);
    _saveSnippets();
  }

  void _saveSnippets() {
    final list = _snippets.map((s) => s.toJson()).toList();
    _vault.writeEncryptedJson(_snippetsFile, list);
  }

  Future<void> _showSnippetDialog({SshSnippet? existing}) async {
    final result = await showDialog<SshSnippet>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => SshSnippetEditorDialog(
        isDark: widget.isDark,
        initialSnippet: existing,
      ),
    );
    if (result != null) {
      setState(() {
        if (existing != null) {
          final idx = _snippets.indexWhere((s) => s.id == existing.id);
          if (idx >= 0) {
            _snippets[idx] = result;
          }
        } else {
          _snippets.add(result);
        }
      });
      _saveSnippets();
    }
  }

  void _deleteSnippet(SshSnippet snippet) {
    setState(() {
      _snippets.removeWhere((s) => s.id == snippet.id);
    });
    _saveSnippets();
  }

  void _openTerminalTab(SshHostConfig host, {String? initialDir}) {
    final tab = WorkspaceSessionTab(
      tabId: 'term_${host.id}_${DateTime.now().millisecondsSinceEpoch}',
      host: host,
      type: WorkspaceTabType.terminal,
      initialDirectory: initialDir,
    );
    setState(() {
      _openTabs.add(tab);
      _activeTabIndex = _openTabs.length - 1;
    });
  }

  void _openSftpTab(SshHostConfig host, {String? initialDir}) {
    final tab = WorkspaceSessionTab(
      tabId: 'sftp_${host.id}_${DateTime.now().millisecondsSinceEpoch}',
      host: host,
      type: WorkspaceTabType.sftp,
      initialDirectory: initialDir,
    );
    setState(() {
      _openTabs.add(tab);
      _activeTabIndex = _openTabs.length - 1;
    });
  }

  void _closeTab(int index) {
    setState(() {
      _openTabs.removeAt(index);
      if (_activeTabIndex >= _openTabs.length) {
        _activeTabIndex = _openTabs.isEmpty ? 0 : _openTabs.length - 1;
      }
    });
  }

  Future<void> _showHostDialog({SshHostConfig? existing}) async {
    final result = await showDialog<SshHostConfig>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => SshHostEditorDialog(
        isDark: widget.isDark,
        initialHost: existing,
      ),
    );
    if (result != null) {
      setState(() {
        if (existing != null) {
          final idx = _hosts.indexWhere((h) => h.id == existing.id);
          if (idx >= 0) {
            _hosts[idx] = result;
          }
        } else {
          _hosts.add(result);
        }
      });
      _saveHosts();
    }
  }

  void _deleteHost(SshHostConfig host) {
    host.deleteSecretsFromVault(_vault);
    setState(() {
      _hosts.removeWhere((h) => h.id == host.id);
    });
    _saveHosts();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    final cardBg = isDark ? const Color(0xFF162032) : Colors.white;
    final borderCol =
        isDark ? const Color(0xFF26354D) : const Color(0xFFE2E8F0);
    final textPrimary = isDark ? Colors.white : const Color(0xFF0F172A);
    final textSecondary =
        isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);

    final filteredHosts = _hosts.where((h) {
      if (_searchQuery.trim().isEmpty) return true;
      final q = _searchQuery.toLowerCase();
      return h.name.toLowerCase().contains(q) ||
          h.address.toLowerCase().contains(q) ||
          h.username.toLowerCase().contains(q) ||
          h.group.toLowerCase().contains(q);
    }).toList();

    return Padding(
      padding: const EdgeInsets.all(14.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Left Column: Collapsible Hosts Manager Sidebar
          if (_isSidebarVisible) ...[
            SizedBox(
              width: 320,
              child: Container(
                decoration: BoxDecoration(
                  color: cardBg,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: borderCol),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(14, 12, 10, 10),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.dns_rounded,
                            size: 20,
                            color: Color(0xFF22C55E),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Hosts SSH & SFTP',
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w800,
                                color: textPrimary,
                              ),
                            ),
                          ),
                          ElevatedButton.icon(
                            onPressed: () => _showHostDialog(),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF15803D),
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 8,
                              ),
                              minimumSize: Size.zero,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(9),
                              ),
                            ),
                            icon: const Icon(Icons.add_rounded, size: 16),
                            label: const Text(
                              'Novo Host',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                          const SizedBox(width: 4),
                          IconButton(
                            onPressed: () =>
                                setState(() => _isSidebarVisible = false),
                            tooltip: 'Ocultar barra lateral de Hosts',
                            visualDensity: VisualDensity.compact,
                            icon: SidebarToggleIcon(
                              isLeft: true,
                              isOpen: true,
                              color: textSecondary,
                              size: 18,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: TextField(
                        onChanged: (v) => setState(() => _searchQuery = v),
                        style: TextStyle(fontSize: 12.5, color: textPrimary),
                        decoration: InputDecoration(
                          hintText: 'Buscar servidor, IP ou usuário...',
                          isDense: true,
                          prefixIcon:
                              const Icon(Icons.search_rounded, size: 18),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 9,
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Divider(color: borderCol, height: 1),
                    Expanded(
                      child: filteredHosts.isEmpty
                          ? Center(
                              child: Padding(
                                padding: const EdgeInsets.all(20.0),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      Icons.terminal_rounded,
                                      size: 42,
                                      color:
                                          textSecondary.withValues(alpha: 0.45),
                                    ),
                                    const SizedBox(height: 10),
                                    Text(
                                      _hosts.isEmpty
                                          ? 'Nenhum servidor cadastrado.\nClique em "+ Novo Host" para adicionar.'
                                          : 'Nenhum host encontrado para a busca.',
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                        color: textSecondary,
                                        fontSize: 12.5,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            )
                          : ListView.separated(
                              padding: const EdgeInsets.all(10),
                              itemCount: filteredHosts.length,
                              separatorBuilder: (_, __) =>
                                  const SizedBox(height: 8),
                              itemBuilder: (ctx, idx) {
                                final host = filteredHosts[idx];
                                return _buildHostItemCard(
                                  host: host,
                                  isDark: isDark,
                                  borderCol: borderCol,
                                  textPrimary: textPrimary,
                                  textSecondary: textSecondary,
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 14),
          ] else ...[
            InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: () => setState(() => _isSidebarVisible = true),
              child: Container(
                width: 40,
                decoration: BoxDecoration(
                  color: cardBg,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: borderCol),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const SidebarToggleIcon(
                      isLeft: true,
                      isOpen: false,
                      color: Color(0xFF22C55E),
                      size: 19,
                    ),
                    const SizedBox(height: 12),
                    RotatedBox(
                      quarterTurns: 3,
                      child: Text(
                        'Hosts SSH & SFTP',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: textPrimary,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 10),
          ],
          // Right Column: Active Sessions (Terminals & SFTP)
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: cardBg,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: borderCol),
              ),
              child: _openTabs.isEmpty
                  ? _buildEmptyWorkspacePlaceholder(
                      textPrimary: textPrimary,
                      textSecondary: textSecondary,
                    )
                  : Column(
                      children: [
                        _buildWorkspaceTabBar(
                          isDark: isDark,
                          borderCol: borderCol,
                          textPrimary: textPrimary,
                          textSecondary: textSecondary,
                        ),
                        Expanded(
                          child: IndexedStack(
                            index: _activeTabIndex,
                            children: _openTabs.map((tab) {
                              if (tab.type == WorkspaceTabType.terminal) {
                                return SshTerminalTabWidget(
                                  key: ValueKey(tab.tabId),
                                  host: tab.host,
                                  sshHelper: _sshHelper,
                                  isDark: isDark,
                                  initialDirectory: tab.initialDirectory,
                                  snippets: _snippets,
                                  onAddSnippet: () => _showSnippetDialog(),
                                  onEditSnippet: (s) =>
                                      _showSnippetDialog(existing: s),
                                  onDeleteSnippet: _deleteSnippet,
                                  onOpenSftp: (dir) =>
                                      _openSftpTab(tab.host, initialDir: dir),
                                );
                              } else {
                                return SftpExplorerTabWidget(
                                  key: ValueKey(tab.tabId),
                                  host: tab.host,
                                  sshHelper: _sshHelper,
                                  isDark: isDark,
                                  initialDirectory: tab.initialDirectory,
                                  onOpenTerminalAt: (dir) => _openTerminalTab(
                                      tab.host,
                                      initialDir: dir),
                                );
                              }
                            }).toList(),
                          ),
                        ),
                      ],
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHostItemCard({
    required SshHostConfig host,
    required bool isDark,
    required Color borderCol,
    required Color textPrimary,
    required Color textSecondary,
  }) {
    final itemBg = isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC);

    return Container(
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: itemBg,
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: borderCol),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(7),
                decoration: BoxDecoration(
                  color: const Color(0xFF15803D).withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(
                  Icons.computer_rounded,
                  size: 17,
                  color: Color(0xFF22C55E),
                ),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      host.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                        color: textPrimary,
                      ),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      '${host.username}@${host.address}:${host.port}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11.5,
                        fontFamily: 'monospace',
                        color: textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 2.5),
                decoration: BoxDecoration(
                  color: const Color(0xFF3B82F6).withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  host.summaryBadge,
                  style: const TextStyle(
                    fontSize: 9.5,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF60A5FA),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: () => _openTerminalTab(host),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF15803D),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 7),
                    minimumSize: Size.zero,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  icon: const Icon(Icons.terminal_rounded, size: 15),
                  label: const Text(
                    'SSH Terminal',
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _openSftpTab(host),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 7),
                    minimumSize: Size.zero,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  icon: const Icon(Icons.folder_copy_outlined, size: 15),
                  label: const Text(
                    'SFTP',
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 4),
              IconButton(
                onPressed: () => _showHostDialog(existing: host),
                tooltip: 'Editar Host',
                visualDensity: VisualDensity.compact,
                icon: Icon(Icons.edit_outlined, size: 17, color: textSecondary),
              ),
              IconButton(
                onPressed: () => _deleteHost(host),
                tooltip: 'Excluir Host',
                visualDensity: VisualDensity.compact,
                icon: const Icon(
                  Icons.delete_outline_rounded,
                  size: 17,
                  color: Color(0xFFEF4444),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyWorkspacePlaceholder({
    required Color textPrimary,
    required Color textSecondary,
  }) {
    return Stack(
      children: [
        if (!_isSidebarVisible)
          Positioned(
            top: 10,
            left: 10,
            child: OutlinedButton.icon(
              onPressed: () => setState(() => _isSidebarVisible = true),
              icon: const SidebarToggleIcon(
                isLeft: true,
                isOpen: false,
                color: Color(0xFF22C55E),
                size: 17,
              ),
              label: const Text('Mostrar Hosts'),
            ),
          ),
        Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: const Color(0xFF15803D).withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.terminal_rounded,
                  size: 48,
                  color: Color(0xFF22C55E),
                ),
              ),
              const SizedBox(height: 14),
              Text(
                'Terminal SSH Interativo & SFTP Integrado',
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                  color: textPrimary,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Selecione um servidor à esquerda e clique em "SSH Terminal" ou "SFTP",\n'
                'ou cadastre um novo servidor com Senha, Chave (.pem/.ppk), Certificado ou FIDO2.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: textSecondary),
              ),
              const SizedBox(height: 18),
              ElevatedButton.icon(
                onPressed: () => _showHostDialog(),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF15803D),
                  foregroundColor: Colors.white,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                icon: const Icon(Icons.add_circle_outline_rounded),
                label: const Text(
                  'Adicionar Servidor SSH / SFTP',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildWorkspaceTabBar({
    required bool isDark,
    required Color borderCol,
    required Color textPrimary,
    required Color textSecondary,
  }) {
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: borderCol)),
      ),
      child: Row(
        children: [
          Tooltip(
            message: _isSidebarVisible
                ? 'Ocultar barra lateral de Hosts'
                : 'Mostrar barra lateral de Hosts',
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () =>
                  setState(() => _isSidebarVisible = !_isSidebarVisible),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                decoration: BoxDecoration(
                  color: !_isSidebarVisible
                      ? const Color(0xFF15803D).withValues(alpha: 0.18)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: !_isSidebarVisible
                        ? const Color(0xFF22C55E)
                        : borderCol,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SidebarToggleIcon(
                      isLeft: true,
                      isOpen: _isSidebarVisible,
                      color: !_isSidebarVisible
                          ? const Color(0xFF4ADE80)
                          : textSecondary,
                      size: 17,
                    ),
                    if (!_isSidebarVisible) ...[
                      const SizedBox(width: 6),
                      Text(
                        'Hosts',
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w700,
                          color: textPrimary,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: _openTabs.length,
              separatorBuilder: (_, __) => const SizedBox(width: 6),
              itemBuilder: (ctx, idx) {
                final tab = _openTabs[idx];
                final active = idx == _activeTabIndex;
                final isTerm = tab.type == WorkspaceTabType.terminal;

                return InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () => setState(() => _activeTabIndex = idx),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    decoration: BoxDecoration(
                      color: active
                          ? const Color(0xFF15803D).withValues(alpha: 0.2)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: active ? const Color(0xFF22C55E) : borderCol,
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          isTerm
                              ? Icons.terminal_rounded
                              : Icons.folder_open_rounded,
                          size: 15,
                          color: isTerm
                              ? const Color(0xFF4ADE80)
                              : const Color(0xFF38BDF8),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          '${tab.host.name} (${isTerm ? "SSH" : "SFTP"})',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight:
                                active ? FontWeight.w700 : FontWeight.w500,
                            color: textPrimary,
                          ),
                        ),
                        const SizedBox(width: 6),
                        InkWell(
                          onTap: () => _closeTab(idx),
                          child: Icon(
                            Icons.close_rounded,
                            size: 15,
                            color: textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Interactive Embedded SSH Terminal Tab (powered by xterm + local Python PTY + Snippets)
class SshTerminalTabWidget extends StatefulWidget {
  final SshHostConfig host;
  final SshHelperManager sshHelper;
  final bool isDark;
  final String? initialDirectory;
  final List<SshSnippet> snippets;
  final VoidCallback onAddSnippet;
  final void Function(SshSnippet snippet) onEditSnippet;
  final void Function(SshSnippet snippet) onDeleteSnippet;
  final void Function(String? currentDir) onOpenSftp;

  const SshTerminalTabWidget({
    super.key,
    required this.host,
    required this.sshHelper,
    required this.isDark,
    this.initialDirectory,
    required this.snippets,
    required this.onAddSnippet,
    required this.onEditSnippet,
    required this.onDeleteSnippet,
    required this.onOpenSftp,
  });

  @override
  State<SshTerminalTabWidget> createState() => _SshTerminalTabWidgetState();
}

class _SshTerminalTabWidgetState extends State<SshTerminalTabWidget> {
  late final Terminal _terminal;
  final TerminalController _terminalController = TerminalController();
  Process? _ptyProc;
  File? _askPassFile;
  bool _isConnected = false;
  bool _showSnippetsPanel = true;
  String _snippetSearch = '';
  String _selectedCategory = 'Todos';

  @override
  void initState() {
    super.initState();
    _terminal = Terminal(maxLines: 10000);
    _startSshPtySession();
  }

  @override
  void dispose() {
    _killPty();
    _terminalController.dispose();
    super.dispose();
  }

  void _killPty() {
    try {
      _ptyProc?.kill(ProcessSignal.sigterm);
    } catch (_) {}
    try {
      _askPassFile?.deleteSync();
    } catch (_) {}
  }

  void _sendPtyResize(int cols, int rows) {
    final proc = _ptyProc;
    if (proc == null) return;
    try {
      final msg = jsonEncode({'t': 'r', 'cols': cols, 'rows': rows});
      proc.stdin.writeln(msg);
    } catch (_) {}
  }

  void _sendPtyData(String data) {
    final proc = _ptyProc;
    if (proc == null) return;
    try {
      final msg = jsonEncode({'t': 'd', 'd': data});
      proc.stdin.writeln(msg);
    } catch (_) {}
  }

  void _runSnippet(SshSnippet snippet, {required bool executeNow}) {
    String payload = snippet.command;
    if (executeNow && !payload.endsWith('\n')) {
      payload += '\n';
    }
    _sendPtyData(payload);
  }

  Color _categoryAccentColor(String category) {
    switch (category.toLowerCase()) {
      case 'deploy':
        return const Color(0xFF4ADE80);
      case 'docker':
        return const Color(0xFF38BDF8);
      case 'sistema':
        return const Color(0xFFFBBF24);
      case 'banco':
        return const Color(0xFFC084FC);
      case 'logs':
        return const Color(0xFFFB7185);
      default:
        return const Color(0xFF2DD4BF);
    }
  }

  Future<void> _startSshPtySession() async {
    _killPty();
    final host = widget.host;

    _terminal.write(
      '\x1b[1;32m● Conectando via SSH a ${host.username}@${host.address}:${host.port} (${host.summaryBadge})...\x1b[0m\r\n',
    );

    final commonOpts = await widget.sshHelper.buildCommonSshOptions(host);
    _askPassFile = widget.sshHelper.createAskPassScript(host);

    final cleanEnv = Map<String, String>.from(Platform.environment)
      ..remove('LD_LIBRARY_PATH')
      ..remove('PYTHONHOME')
      ..remove('PYTHONPATH');

    if (_askPassFile != null) {
      cleanEnv['SSH_ASKPASS'] = _askPassFile!.path;
      cleanEnv['SSH_ASKPASS_REQUIRE'] = 'force';
      cleanEnv['DISPLAY'] = cleanEnv['DISPLAY'] ?? ':0';
    }

    final sshArgs = <String>[
      'ssh',
      '-tt',
      '-p',
      host.port.toString(),
      ...commonOpts,
      '${host.username}@${host.address}',
    ];

    if (widget.initialDirectory != null &&
        widget.initialDirectory!.trim().isNotEmpty) {
      final safeSingleQuoted =
          widget.initialDirectory!.replaceAll("'", r"'\''");
      sshArgs.add("cd -- '$safeSingleQuoted' && exec \$SHELL -l");
    } else if (host.startupCommand.trim().isNotEmpty) {
      sshArgs.add('${host.startupCommand.trim()}; exec \$SHELL -l');
    }

    try {
      final proc = await Process.start(
        '/usr/bin/python3',
        [widget.sshHelper.ptyBridgeScript.path, ...sshArgs],
        environment: cleanEnv,
      );
      _ptyProc = proc;
      // Delete temporary askpass script shortly after handshake
      final askRef = _askPassFile;
      if (askRef != null) {
        Future.delayed(const Duration(seconds: 8), () {
          try {
            if (askRef.existsSync()) askRef.deleteSync();
          } catch (_) {}
        });
      }
      if (mounted) {
        setState(() => _isConnected = true);
      }

      _terminal.onOutput = (data) {
        _sendPtyData(data);
      };

      _terminal.onResize = (w, h, pw, ph) {
        _sendPtyResize(w, h);
      };

      proc.stdout.transform(const Utf8Decoder(allowMalformed: true)).listen(
        (chunk) {
          _terminal.write(chunk);
        },
      );

      proc.stderr.transform(const Utf8Decoder(allowMalformed: true)).listen(
        (chunk) {
          _terminal.write(chunk);
        },
      );

      final code = await proc.exitCode;
      if (mounted) {
        setState(() => _isConnected = false);
      }
      _terminal.write(
        '\r\n\x1b[1;33m[Sessão SSH encerrada (cód. $code). Clique em Reconectar para abrir novamente.]\x1b[0m\r\n',
      );
    } catch (e) {
      _terminal.write('\r\n\x1b[1;31mErro ao iniciar SSH: $e\x1b[0m\r\n');
    } finally {
      try {
        _askPassFile?.deleteSync();
      } catch (_) {}
    }
  }

  @override
  Widget build(BuildContext context) {
    final host = widget.host;
    final isDark = widget.isDark;
    final panelBg = isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC);
    final borderCol =
        isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0);
    final textPrimary = isDark ? Colors.white : const Color(0xFF0F172A);
    final textSecondary =
        isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);

    // Collect distinct categories
    final categories = <String>{'Todos'};
    for (final s in widget.snippets) {
      if (s.category.trim().isNotEmpty) {
        categories.add(s.category.trim());
      }
    }
    if (!categories.contains(_selectedCategory)) {
      _selectedCategory = 'Todos';
    }

    final filteredSnippets = widget.snippets.where((s) {
      if (_selectedCategory != 'Todos' &&
          s.category.trim().toLowerCase() !=
              _selectedCategory.toLowerCase()) {
        return false;
      }
      if (_snippetSearch.trim().isEmpty) return true;
      final q = _snippetSearch.toLowerCase();
      return s.title.toLowerCase().contains(q) ||
          s.command.toLowerCase().contains(q) ||
          s.category.toLowerCase().contains(q);
    }).toList();

    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          color: const Color(0xFF0B1120),
          child: Row(
            children: [
              Container(
                width: 9,
                height: 9,
                decoration: BoxDecoration(
                  color: _isConnected
                      ? const Color(0xFF22C55E)
                      : const Color(0xFFEF4444),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${host.name} • ${host.username}@${host.address}:${host.port}',
                  style: const TextStyle(
                    fontSize: 12.5,
                    color: Colors.white,
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              TextButton.icon(
                onPressed: () =>
                    setState(() => _showSnippetsPanel = !_showSnippetsPanel),
                style: TextButton.styleFrom(
                  backgroundColor: _showSnippetsPanel
                      ? const Color(0xFF22C55E).withValues(alpha: 0.16)
                      : Colors.white.withValues(alpha: 0.05),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                icon: Icon(
                  Icons.terminal_rounded,
                  size: 15,
                  color: _showSnippetsPanel
                      ? const Color(0xFF4ADE80)
                      : const Color(0xFFFBBF24),
                ),
                label: Text(
                  'Snippets (${widget.snippets.length})',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: _showSnippetsPanel
                        ? const Color(0xFF4ADE80)
                        : const Color(0xFFFBBF24),
                  ),
                ),
              ),
              const SizedBox(width: 4),
              TextButton.icon(
                onPressed: () => widget.onOpenSftp(widget.initialDirectory),
                icon: const Icon(Icons.folder_open_rounded,
                    size: 15, color: Color(0xFF38BDF8)),
                label: const Text(
                  'Abrir SFTP',
                  style: TextStyle(fontSize: 12, color: Color(0xFF38BDF8)),
                ),
              ),
              TextButton.icon(
                onPressed: () async {
                  final data = await Clipboard.getData(Clipboard.kTextPlain);
                  if (data?.text != null && data!.text!.isNotEmpty) {
                    _sendPtyData(data.text!);
                  }
                },
                icon: const Icon(Icons.paste_rounded,
                    size: 15, color: Colors.white70),
                label: const Text(
                  'Colar',
                  style: TextStyle(fontSize: 12, color: Colors.white70),
                ),
              ),
              TextButton.icon(
                onPressed: _startSshPtySession,
                icon: const Icon(Icons.refresh_rounded,
                    size: 16, color: Color(0xFF4ADE80)),
                label: const Text(
                  'Reconectar',
                  style: TextStyle(fontSize: 12, color: Color(0xFF4ADE80)),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.only(
                    bottomLeft: const Radius.circular(13),
                    bottomRight: _showSnippetsPanel
                        ? Radius.zero
                        : const Radius.circular(13),
                  ),
                  child: TerminalView(
                    _terminal,
                    controller: _terminalController,
                    autofocus: true,
                    backgroundOpacity: 1.0,
                    padding: const EdgeInsets.all(10),
                  ),
                ),
              ),
              if (_showSnippetsPanel)
                Container(
                  width: 310,
                  decoration: BoxDecoration(
                    color: panelBg,
                    border: Border(left: BorderSide(color: borderCol)),
                    borderRadius: const BorderRadius.only(
                      bottomRight: Radius.circular(13),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Clean Modern Header
                      Padding(
                        padding: const EdgeInsets.fromLTRB(14, 12, 10, 10),
                        child: Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(6),
                              decoration: BoxDecoration(
                                color: const Color(0xFF22C55E)
                                    .withValues(alpha: 0.14),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: const Icon(
                                Icons.code_rounded,
                                size: 16,
                                color: Color(0xFF4ADE80),
                              ),
                            ),
                            const SizedBox(width: 9),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Snippets',
                                    style: TextStyle(
                                      fontSize: 13.5,
                                      fontWeight: FontWeight.w800,
                                      color: textPrimary,
                                      letterSpacing: 0.2,
                                    ),
                                  ),
                                  Text(
                                    'Comandos rápidos SSH',
                                    style: TextStyle(
                                      fontSize: 10.5,
                                      color: textSecondary,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            InkWell(
                              borderRadius: BorderRadius.circular(8),
                              onTap: widget.onAddSnippet,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 6,
                                ),
                                decoration: BoxDecoration(
                                  gradient: const LinearGradient(
                                    colors: [
                                      Color(0xFF15803D),
                                      Color(0xFF16A34A),
                                    ],
                                  ),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: const Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      Icons.add_rounded,
                                      size: 15,
                                      color: Colors.white,
                                    ),
                                    SizedBox(width: 3),
                                    Text(
                                      'Novo',
                                      style: TextStyle(
                                        fontSize: 11.5,
                                        fontWeight: FontWeight.w700,
                                        color: Colors.white,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            const SizedBox(width: 4),
                            IconButton(
                              onPressed: () =>
                                  setState(() => _showSnippetsPanel = false),
                              tooltip: 'Ocultar Sidebar Direita (Snippets)',
                              visualDensity: VisualDensity.compact,
                              icon: SidebarToggleIcon(
                                isLeft: false,
                                isOpen: true,
                                color: textSecondary,
                                size: 18,
                              ),
                            ),
                          ],
                        ),
                      ),

                      // Sleek Search Input
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Container(
                          height: 34,
                          decoration: BoxDecoration(
                            color: isDark
                                ? const Color(0xFF1E293B).withValues(alpha: 0.7)
                                : Colors.white,
                            borderRadius: BorderRadius.circular(9),
                            border: Border.all(color: borderCol),
                          ),
                          child: TextField(
                            onChanged: (v) =>
                                setState(() => _snippetSearch = v),
                            style:
                                TextStyle(fontSize: 12, color: textPrimary),
                            decoration: InputDecoration(
                              hintText: 'Buscar snippet ou comando...',
                              hintStyle: TextStyle(
                                fontSize: 11.5,
                                color: textSecondary,
                              ),
                              isDense: true,
                              prefixIcon: Icon(
                                Icons.search_rounded,
                                size: 16,
                                color: textSecondary,
                              ),
                              border: InputBorder.none,
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 8,
                              ),
                            ),
                          ),
                        ),
                      ),

                      // Clean Category Filter Pills
                      if (categories.length > 1)
                        SizedBox(
                          height: 36,
                          child: ListView.separated(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 6,
                            ),
                            scrollDirection: Axis.horizontal,
                            itemCount: categories.length,
                            separatorBuilder: (_, __) =>
                                const SizedBox(width: 6),
                            itemBuilder: (ctx, idx) {
                              final cat = categories.elementAt(idx);
                              final selected = cat == _selectedCategory;
                              return InkWell(
                                borderRadius: BorderRadius.circular(20),
                                onTap: () =>
                                    setState(() => _selectedCategory = cat),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 3,
                                  ),
                                  decoration: BoxDecoration(
                                    color: selected
                                        ? const Color(0xFF22C55E)
                                            .withValues(alpha: 0.18)
                                        : (isDark
                                            ? const Color(0xFF1E293B)
                                                .withValues(alpha: 0.5)
                                            : Colors.white),
                                    borderRadius: BorderRadius.circular(20),
                                    border: Border.all(
                                      color: selected
                                          ? const Color(0xFF22C55E)
                                          : borderCol,
                                    ),
                                  ),
                                  alignment: Alignment.center,
                                  child: Text(
                                    cat,
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: selected
                                          ? FontWeight.w700
                                          : FontWeight.w500,
                                      color: selected
                                          ? const Color(0xFF4ADE80)
                                          : textSecondary,
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                        )
                      else
                        const SizedBox(height: 8),

                      Divider(color: borderCol, height: 1),

                      // Snippets List
                      Expanded(
                        child: filteredSnippets.isEmpty
                            ? Center(
                                child: Padding(
                                  padding: const EdgeInsets.all(20.0),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        Icons.code_off_rounded,
                                        size: 34,
                                        color: textSecondary.withValues(
                                            alpha: 0.4),
                                      ),
                                      const SizedBox(height: 8),
                                      Text(
                                        'Nenhum snippet encontrado.\nClique em "+ Novo" para criar.',
                                        textAlign: TextAlign.center,
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: textSecondary,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              )
                            : ListView.separated(
                                padding: const EdgeInsets.all(11),
                                itemCount: filteredSnippets.length,
                                separatorBuilder: (_, __) =>
                                    const SizedBox(height: 9),
                                itemBuilder: (ctx, idx) {
                                  final s = filteredSnippets[idx];
                                  final catColor =
                                      _categoryAccentColor(s.category);

                                  return Container(
                                    padding: const EdgeInsets.all(11),
                                    decoration: BoxDecoration(
                                      color: isDark
                                          ? const Color(0xFF162032)
                                          : Colors.white,
                                      borderRadius: BorderRadius.circular(11),
                                      border: Border.all(color: borderCol),
                                    ),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.stretch,
                                      children: [
                                        // Top Row: Dot + Title + Category Tag + Subtle Actions
                                        Row(
                                          children: [
                                            Container(
                                              width: 7,
                                              height: 7,
                                              decoration: BoxDecoration(
                                                color: catColor,
                                                shape: BoxShape.circle,
                                              ),
                                            ),
                                            const SizedBox(width: 7),
                                            Expanded(
                                              child: Text(
                                                s.title,
                                                style: TextStyle(
                                                  fontSize: 12.5,
                                                  fontWeight: FontWeight.w700,
                                                  color: textPrimary,
                                                ),
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ),
                                            Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                horizontal: 6,
                                                vertical: 2,
                                              ),
                                              decoration: BoxDecoration(
                                                color: catColor.withValues(
                                                    alpha: 0.13),
                                                borderRadius:
                                                    BorderRadius.circular(6),
                                              ),
                                              child: Text(
                                                s.category,
                                                style: TextStyle(
                                                  fontSize: 9.5,
                                                  fontWeight: FontWeight.w700,
                                                  color: catColor,
                                                ),
                                              ),
                                            ),
                                            const SizedBox(width: 4),
                                            Tooltip(
                                              message:
                                                  'Inserir no terminal (sem Enter)',
                                              child: InkWell(
                                                borderRadius:
                                                    BorderRadius.circular(5),
                                                onTap: () => _runSnippet(
                                                  s,
                                                  executeNow: false,
                                                ),
                                                child: Padding(
                                                  padding:
                                                      const EdgeInsets.all(3.5),
                                                  child: Icon(
                                                    Icons.keyboard_rounded,
                                                    size: 14,
                                                    color: textSecondary,
                                                  ),
                                                ),
                                              ),
                                            ),
                                            Tooltip(
                                              message: 'Editar Snippet',
                                              child: InkWell(
                                                borderRadius:
                                                    BorderRadius.circular(5),
                                                onTap: () =>
                                                    widget.onEditSnippet(s),
                                                child: Padding(
                                                  padding:
                                                      const EdgeInsets.all(3.5),
                                                  child: Icon(
                                                    Icons.edit_outlined,
                                                    size: 14,
                                                    color: textSecondary,
                                                  ),
                                                ),
                                              ),
                                            ),
                                            Tooltip(
                                              message: 'Excluir Snippet',
                                              child: InkWell(
                                                borderRadius:
                                                    BorderRadius.circular(5),
                                                onTap: () =>
                                                    widget.onDeleteSnippet(s),
                                                child: Padding(
                                                  padding:
                                                      const EdgeInsets.all(3.5),
                                                  child: Icon(
                                                    Icons
                                                        .delete_outline_rounded,
                                                    size: 14,
                                                    color: textSecondary
                                                        .withValues(alpha: 0.8),
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 8),

                                        // Bottom Sleek Code Bar with integrated Run button
                                        InkWell(
                                          borderRadius:
                                              BorderRadius.circular(8),
                                          onTap: () => _runSnippet(
                                            s,
                                            executeNow: s.autoEnter,
                                          ),
                                          child: Container(
                                            padding: const EdgeInsets.fromLTRB(
                                                9, 6, 6, 6),
                                            decoration: BoxDecoration(
                                              color: const Color(0xFF0B1120),
                                              borderRadius:
                                                  BorderRadius.circular(8),
                                              border: Border.all(
                                                color: const Color(0xFF1E293B),
                                              ),
                                            ),
                                            child: Row(
                                              children: [
                                                const Text(
                                                  r'$ ',
                                                  style: TextStyle(
                                                    fontFamily: 'monospace',
                                                    fontSize: 11,
                                                    fontWeight: FontWeight.bold,
                                                    color: Color(0xFF64748B),
                                                  ),
                                                ),
                                                Expanded(
                                                  child: Text(
                                                    s.command,
                                                    maxLines: 2,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style: const TextStyle(
                                                      fontFamily: 'monospace',
                                                      fontSize: 11,
                                                      color: Color(0xFFE2E8F0),
                                                    ),
                                                  ),
                                                ),
                                                const SizedBox(width: 6),
                                                Container(
                                                  padding: const EdgeInsets
                                                      .symmetric(
                                                    horizontal: 8,
                                                    vertical: 4,
                                                  ),
                                                  decoration: BoxDecoration(
                                                    color:
                                                        const Color(0xFF15803D)
                                                            .withValues(
                                                                alpha: 0.28),
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                            6),
                                                    border: Border.all(
                                                      color: const Color(
                                                              0xFF22C55E)
                                                          .withValues(
                                                              alpha: 0.45),
                                                    ),
                                                  ),
                                                  child: const Row(
                                                    mainAxisSize:
                                                        MainAxisSize.min,
                                                    children: [
                                                      Icon(
                                                        Icons
                                                            .play_arrow_rounded,
                                                        size: 13,
                                                        color:
                                                            Color(0xFF4ADE80),
                                                      ),
                                                      SizedBox(width: 2),
                                                      Text(
                                                        'Run',
                                                        style: TextStyle(
                                                          fontSize: 10.5,
                                                          fontWeight:
                                                              FontWeight.w800,
                                                          color:
                                                              Color(0xFF4ADE80),
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  );
                                },
                              ),
                      ),
                    ],
                  ),
                )
              else
                InkWell(
                  onTap: () => setState(() => _showSnippetsPanel = true),
                  child: Container(
                    width: 36,
                    decoration: BoxDecoration(
                      color: panelBg,
                      border: Border(left: BorderSide(color: borderCol)),
                      borderRadius: const BorderRadius.only(
                        bottomRight: Radius.circular(13),
                      ),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const SidebarToggleIcon(
                          isLeft: false,
                          isOpen: false,
                          color: Color(0xFF4ADE80),
                          size: 18,
                        ),
                        const SizedBox(height: 10),
                        RotatedBox(
                          quarterTurns: 1,
                          child: Text(
                            'Snippets (${widget.snippets.length})',
                            style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w700,
                              color: textPrimary,
                              letterSpacing: 0.4,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class SshSnippetEditorDialog extends StatefulWidget {
  final bool isDark;
  final SshSnippet? initialSnippet;

  const SshSnippetEditorDialog({
    super.key,
    required this.isDark,
    this.initialSnippet,
  });

  @override
  State<SshSnippetEditorDialog> createState() => _SshSnippetEditorDialogState();
}

class _SshSnippetEditorDialogState extends State<SshSnippetEditorDialog> {
  static const List<String> _presetCategories = [
    'Geral',
    'Deploy',
    'Docker',
    'Sistema',
    'Logs',
    'Banco',
  ];

  late final TextEditingController _titleCtrl;
  late final TextEditingController _categoryCtrl;
  late final TextEditingController _commandCtrl;
  bool _autoEnter = true;

  @override
  void initState() {
    super.initState();
    final s = widget.initialSnippet;
    _titleCtrl = TextEditingController(text: s?.title ?? '');
    _categoryCtrl = TextEditingController(text: s?.category ?? 'Geral');
    _commandCtrl = TextEditingController(text: s?.command ?? '');
    _autoEnter = s?.autoEnter ?? true;
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _categoryCtrl.dispose();
    _commandCtrl.dispose();
    super.dispose();
  }

  void _save() {
    if (_titleCtrl.text.trim().isEmpty || _commandCtrl.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Informe o nome e o comando do Snippet.'),
          backgroundColor: Color(0xFFDC2626),
        ),
      );
      return;
    }

    final snippet = SshSnippet(
      id: widget.initialSnippet?.id ??
          DateTime.now().millisecondsSinceEpoch.toString(),
      title: _titleCtrl.text.trim(),
      category: _categoryCtrl.text.trim().isEmpty
          ? 'Geral'
          : _categoryCtrl.text.trim(),
      command: _commandCtrl.text.trim(),
      autoEnter: _autoEnter,
    );
    Navigator.pop(context, snippet);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    final borderCol =
        isDark ? const Color(0xFF26354D) : const Color(0xFFE2E8F0);

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: SizedBox(
        width: 540,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [Color(0xFF0A3D22), Color(0xFF15803D)],
                ),
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(16),
                  topRight: Radius.circular(16),
                ),
              ),
              child: Row(
                children: [
                  const Icon(Icons.code_rounded, color: Colors.white),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      widget.initialSnippet == null
                          ? 'Novo Snippet de Comando'
                          : 'Editar Snippet de Comando',
                      style: const TextStyle(
                        fontSize: 15.5,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded, color: Colors.white),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(20.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        flex: 2,
                        child: TextField(
                          controller: _titleCtrl,
                          autofocus: true,
                          decoration: const InputDecoration(
                            labelText: 'Nome do Snippet *',
                            hintText: 'Ex: Atualizar Produção',
                            prefixIcon: Icon(Icons.label_outline_rounded),
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextField(
                          controller: _categoryCtrl,
                          onChanged: (_) => setState(() {}),
                          decoration: const InputDecoration(
                            labelText: 'Categoria',
                            hintText: 'Ex: Deploy',
                            prefixIcon: Icon(Icons.folder_outlined),
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: _presetCategories.map((cat) {
                      final active = _categoryCtrl.text.trim().toLowerCase() ==
                          cat.toLowerCase();
                      return InkWell(
                        borderRadius: BorderRadius.circular(16),
                        onTap: () => setState(() => _categoryCtrl.text = cat),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: active
                                ? const Color(0xFF22C55E).withValues(alpha: 0.18)
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: active
                                  ? const Color(0xFF22C55E)
                                  : borderCol,
                            ),
                          ),
                          child: Text(
                            cat,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight:
                                  active ? FontWeight.bold : FontWeight.w500,
                              color: active
                                  ? const Color(0xFF4ADE80)
                                  : Colors.grey,
                            ),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 14),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0B1120),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: borderCol),
                    ),
                    child: TextField(
                      controller: _commandCtrl,
                      maxLines: 4,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12.5,
                        color: Color(0xFF4ADE80),
                      ),
                      decoration: const InputDecoration(
                        labelText: r'Comando SSH ($)',
                        labelStyle: TextStyle(color: Color(0xFF94A3B8)),
                        hintText:
                            'cd /var/www/html && git pull && php artisan optimize:clear',
                        hintStyle: TextStyle(color: Color(0xFF475569)),
                        border: InputBorder.none,
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  SwitchListTile(
                    value: _autoEnter,
                    onChanged: (v) => setState(() => _autoEnter = v),
                    title: const Text(
                      'Executar imediatamente ao clicar (Auto-Enter)',
                      style:
                          TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                    ),
                    subtitle: const Text(
                      'Envia Enter automaticamente no terminal ao clicar no card',
                      style: TextStyle(fontSize: 11.5),
                    ),
                    contentPadding: EdgeInsets.zero,
                  ),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Cancelar'),
                      ),
                      const SizedBox(width: 10),
                      ElevatedButton.icon(
                        onPressed: _save,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF15803D),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 18,
                            vertical: 11,
                          ),
                        ),
                        icon: const Icon(Icons.check_rounded, size: 18),
                        label: const Text(
                          'Salvar Snippet',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Embedded SFTP Remote File Explorer Tab
class SftpExplorerTabWidget extends StatefulWidget {
  final SshHostConfig host;
  final SshHelperManager sshHelper;
  final bool isDark;
  final String? initialDirectory;
  final void Function(String currentDir) onOpenTerminalAt;

  const SftpExplorerTabWidget({
    super.key,
    required this.host,
    required this.sshHelper,
    required this.isDark,
    this.initialDirectory,
    required this.onOpenTerminalAt,
  });

  @override
  State<SftpExplorerTabWidget> createState() => _SftpExplorerTabWidgetState();
}

class _SftpExplorerTabWidgetState extends State<SftpExplorerTabWidget> {
  final TextEditingController _pathCtrl = TextEditingController();
  String _currentPath = '.';
  bool _loading = true;
  String? _error;
  List<SftpRemoteEntry> _entries = [];
  String _statusMessage = '';

  @override
  void initState() {
    super.initState();
    _currentPath = widget.initialDirectory ?? '.';
    _pathCtrl.text = _currentPath;
    _loadDirectory(_currentPath);
  }

  @override
  void dispose() {
    _pathCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadDirectory(String path) async {
    setState(() {
      _loading = true;
      _error = null;
      _statusMessage = 'Listando $path...';
    });

    final (resolved, entries, err) =
        await widget.sshHelper.listRemoteDirectory(widget.host, path);

    if (!mounted) return;
    setState(() {
      _loading = false;
      if (err != null) {
        _error = err;
        _statusMessage = 'Erro ao listar diretório';
      } else {
        _currentPath = resolved;
        _pathCtrl.text = resolved;
        _entries = entries;
        _statusMessage = '${entries.length} itens em $resolved';
      }
    });
  }

  void _navigateUp() {
    if (_currentPath == '/' || _currentPath.isEmpty) return;
    final parts = _currentPath.split('/')..removeLast();
    final parent = parts.join('/');
    _loadDirectory(parent.isEmpty ? '/' : parent);
  }

  Future<void> _uploadFile() async {
    final res = await Process.run('zenity', [
      '--file-selection',
      '--title=Selecionar arquivo para Upload SFTP',
    ]);
    if (res.exitCode != 0) return;
    final localFile = res.stdout.toString().trim();
    if (localFile.isEmpty) return;

    setState(() {
      _loading = true;
      _statusMessage = 'Enviando ${localFile.split('/').last}...';
    });

    final (ok, msg) = await widget.sshHelper.transferFile(
      host: widget.host,
      localPath: localFile,
      remotePath: _currentPath,
      isUpload: true,
    );

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor:
            ok ? const Color(0xFF15803D) : const Color(0xFFDC2626),
      ),
    );
    await _loadDirectory(_currentPath);
  }

  Future<void> _downloadEntry(SftpRemoteEntry entry) async {
    final home = Platform.environment['HOME'] ?? '/tmp';
    final defaultSave = '$home/Downloads/${entry.name}';
    final res = await Process.run('zenity', [
      '--file-selection',
      '--save',
      '--confirm-overwrite',
      '--filename=$defaultSave',
      '--title=Salvar arquivo SFTP como...',
    ]);
    if (res.exitCode != 0) return;
    final savePath = res.stdout.toString().trim();
    if (savePath.isEmpty) return;

    final remoteFull = _currentPath.endsWith('/')
        ? '$_currentPath${entry.name}'
        : '$_currentPath/${entry.name}';

    setState(() {
      _loading = true;
      _statusMessage = 'Baixando ${entry.name}...';
    });

    final (ok, msg) = await widget.sshHelper.transferFile(
      host: widget.host,
      localPath: savePath,
      remotePath: remoteFull,
      isUpload: false,
    );

    if (!mounted) return;
    setState(() => _loading = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor:
            ok ? const Color(0xFF15803D) : const Color(0xFFDC2626),
      ),
    );
  }

  Future<void> _createNewFolder() async {
    final ctrl = TextEditingController();
    final folderName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Nova Pasta Remota (SFTP)'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Nome da pasta',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('Criar'),
          ),
        ],
      ),
    );
    if (folderName == null || folderName.isEmpty) return;

    final target = _currentPath.endsWith('/')
        ? '$_currentPath$folderName'
        : '$_currentPath/$folderName';
    await widget.sshHelper.createRemoteDirectory(widget.host, target);
    await _loadDirectory(_currentPath);
  }

  Future<void> _deleteRemoteEntry(SftpRemoteEntry entry) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Confirmar Exclusão'),
        content: Text('Deseja excluir "${entry.name}" do servidor remoto?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFDC2626),
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Excluir'),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    final target = _currentPath.endsWith('/')
        ? '$_currentPath${entry.name}'
        : '$_currentPath/${entry.name}';
    await widget.sshHelper.deleteRemoteEntry(
      widget.host,
      target,
      isDirectory: entry.isDirectory,
    );
    await _loadDirectory(_currentPath);
  }

  @override
  Widget build(BuildContext context) {
    final textPrimary = widget.isDark ? Colors.white : const Color(0xFF0F172A);
    final textSecondary =
        widget.isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);
    final borderCol =
        widget.isDark ? const Color(0xFF26354D) : const Color(0xFFE2E8F0);

    return Column(
      children: [
        // Top SFTP toolbar
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: borderCol)),
          ),
          child: Row(
            children: [
              IconButton(
                onPressed: _loading ? null : _navigateUp,
                tooltip: 'Subir nível (..)',
                icon: const Icon(Icons.arrow_upward_rounded, size: 19),
              ),
              IconButton(
                onPressed:
                    _loading ? null : () => _loadDirectory(_currentPath),
                tooltip: 'Atualizar',
                icon: const Icon(Icons.refresh_rounded, size: 19),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: TextField(
                  controller: _pathCtrl,
                  onSubmitted: (v) => _loadDirectory(v.trim()),
                  style: TextStyle(
                    fontSize: 13,
                    fontFamily: 'monospace',
                    color: textPrimary,
                  ),
                  decoration: InputDecoration(
                    isDense: true,
                    prefixIcon: const Icon(Icons.folder_special_rounded,
                        size: 18, color: Color(0xFF38BDF8)),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 10,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(9),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: _loading ? null : _createNewFolder,
                icon: const Icon(Icons.create_new_folder_outlined, size: 17),
                label: const Text('Nova Pasta', style: TextStyle(fontSize: 12)),
              ),
              const SizedBox(width: 6),
              ElevatedButton.icon(
                onPressed: _loading ? null : _uploadFile,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF15803D),
                  foregroundColor: Colors.white,
                ),
                icon: const Icon(Icons.upload_file_rounded, size: 17),
                label: const Text('Upload', style: TextStyle(fontSize: 12)),
              ),
              const SizedBox(width: 6),
              OutlinedButton.icon(
                onPressed: () => widget.onOpenTerminalAt(_currentPath),
                icon: const Icon(Icons.terminal_rounded, size: 16),
                label:
                    const Text('Terminal Aqui', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
        ),
        if (_loading) const LinearProgressIndicator(minHeight: 2),
        Expanded(
          child: _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24.0),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.error_outline_rounded,
                            size: 42, color: Color(0xFFEF4444)),
                        const SizedBox(height: 10),
                        Text(
                          _error!,
                          textAlign: TextAlign.center,
                          style: TextStyle(color: textPrimary, fontSize: 13),
                        ),
                        const SizedBox(height: 14),
                        ElevatedButton.icon(
                          onPressed: () => _loadDirectory(_currentPath),
                          icon: const Icon(Icons.refresh_rounded),
                          label: const Text('Tentar Novamente'),
                        ),
                      ],
                    ),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  itemCount: _entries.length,
                  separatorBuilder: (_, __) =>
                      Divider(color: borderCol, height: 1),
                  itemBuilder: (ctx, idx) {
                    final e = _entries[idx];
                    return InkWell(
                      onDoubleTap: () {
                        if (e.isDirectory) {
                          final next = _currentPath.endsWith('/')
                              ? '$_currentPath${e.name}'
                              : '$_currentPath/${e.name}';
                          _loadDirectory(next);
                        } else {
                          _downloadEntry(e);
                        }
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          vertical: 8,
                          horizontal: 6,
                        ),
                        child: Row(
                          children: [
                            Icon(
                              e.isDirectory
                                  ? Icons.folder_rounded
                                  : Icons.insert_drive_file_outlined,
                              size: 21,
                              color: e.isDirectory
                                  ? const Color(0xFFFBBF24)
                                  : const Color(0xFF60A5FA),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                e.name,
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: e.isDirectory
                                      ? FontWeight.w700
                                      : FontWeight.w500,
                                  color: textPrimary,
                                ),
                              ),
                            ),
                            SizedBox(
                              width: 95,
                              child: Text(
                                e.isDirectory ? '<DIR>' : e.size,
                                textAlign: TextAlign.right,
                                style: TextStyle(
                                  fontSize: 12,
                                  fontFamily: 'monospace',
                                  color: textSecondary,
                                ),
                              ),
                            ),
                            const SizedBox(width: 14),
                            SizedBox(
                              width: 130,
                              child: Text(
                                e.date,
                                style: TextStyle(
                                  fontSize: 11.5,
                                  fontFamily: 'monospace',
                                  color: textSecondary,
                                ),
                              ),
                            ),
                            SizedBox(
                              width: 92,
                              child: Text(
                                e.permissions,
                                style: TextStyle(
                                  fontSize: 11.5,
                                  fontFamily: 'monospace',
                                  color: textSecondary,
                                ),
                              ),
                            ),
                            IconButton(
                              onPressed: () => _downloadEntry(e),
                              tooltip: 'Baixar (Download)',
                              visualDensity: VisualDensity.compact,
                              icon: const Icon(
                                Icons.download_rounded,
                                size: 18,
                                color: Color(0xFF22C55E),
                              ),
                            ),
                            IconButton(
                              onPressed: () => _deleteRemoteEntry(e),
                              tooltip: 'Excluir',
                              visualDensity: VisualDensity.compact,
                              icon: const Icon(
                                Icons.delete_outline_rounded,
                                size: 18,
                                color: Color(0xFFEF4444),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: borderCol)),
          ),
          child: Row(
            children: [
              Text(
                _statusMessage,
                style: TextStyle(fontSize: 11.5, color: textSecondary),
              ),
              const Spacer(),
              Text(
                'Dica: Duplo clique em uma pasta para abrir ou em um arquivo para baixar',
                style: TextStyle(fontSize: 11, color: textSecondary),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Complete Dialog to Create or Edit an SSH/SFTP Host (with Password, Key, Certificate, FIDO2, SSH ID, Tunneling)
class SshHostEditorDialog extends StatefulWidget {
  final bool isDark;
  final SshHostConfig? initialHost;

  const SshHostEditorDialog({
    super.key,
    required this.isDark,
    this.initialHost,
  });

  @override
  State<SshHostEditorDialog> createState() => _SshHostEditorDialogState();
}

class _SshHostEditorDialogState extends State<SshHostEditorDialog> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _groupCtrl;
  late final TextEditingController _addressCtrl;
  late final TextEditingController _portCtrl;
  late final TextEditingController _userCtrl;

  late final TextEditingController _passwordCtrl;
  late final List<String> _enabledExtras;
  late final TextEditingController _privateKeyPathCtrl;
  late final TextEditingController _privateKeyContentCtrl;
  late final TextEditingController _passphraseCtrl;
  late final TextEditingController _certificatePathCtrl;
  late final TextEditingController _fido2KeyPathCtrl;
  late final TextEditingController _fido2ProviderCtrl;
  late final TextEditingController _sshIdCtrl;

  late final TextEditingController _proxyJumpCtrl;
  late final TextEditingController _localFwdCtrl;
  late final TextEditingController _remoteFwdCtrl;
  late final TextEditingController _startupCmdCtrl;
  late final TextEditingController _keepAliveCtrl;
  bool _x11Forwarding = false;
  bool _compression = false;
  bool _obscurePassword = true;
  bool _obscurePassphrase = true;

  @override
  void initState() {
    super.initState();
    final h = widget.initialHost;
    _nameCtrl = TextEditingController(text: h?.name ?? '');
    _groupCtrl = TextEditingController(text: h?.group ?? 'Produção');
    _addressCtrl = TextEditingController(text: h?.address ?? '');
    _portCtrl = TextEditingController(text: (h?.port ?? 22).toString());
    _userCtrl = TextEditingController(text: h?.username ?? 'root');

    _passwordCtrl = TextEditingController(text: h?.password ?? '');
    _enabledExtras = List<String>.from(h?.enabledExtras ?? []);
    _privateKeyPathCtrl = TextEditingController(text: h?.privateKeyPath ?? '');
    _privateKeyContentCtrl =
        TextEditingController(text: h?.privateKeyContent ?? '');
    _passphraseCtrl = TextEditingController(text: h?.passphrase ?? '');
    _certificatePathCtrl =
        TextEditingController(text: h?.certificatePath ?? '');
    _fido2KeyPathCtrl = TextEditingController(
        text: h?.fido2KeyPath.isNotEmpty == true
            ? h!.fido2KeyPath
            : '${Platform.environment['HOME'] ?? '/tmp'}/.ssh/id_ed25519_sk');
    _fido2ProviderCtrl =
        TextEditingController(text: h?.fido2Provider ?? 'internal');
    _sshIdCtrl = TextEditingController(
        text: h?.sshId.isNotEmpty == true
            ? h!.sshId
            : '${Platform.environment['HOME'] ?? '/tmp'}/.ssh/id_ed25519');

    _proxyJumpCtrl = TextEditingController(text: h?.proxyJump ?? '');
    _localFwdCtrl = TextEditingController(text: h?.localForward ?? '');
    _remoteFwdCtrl = TextEditingController(text: h?.remoteForward ?? '');
    _startupCmdCtrl = TextEditingController(text: h?.startupCommand ?? '');
    _keepAliveCtrl =
        TextEditingController(text: (h?.keepAliveInterval ?? 30).toString());
    _x11Forwarding = h?.x11Forwarding ?? false;
    _compression = h?.compression ?? false;
  }

  Future<void> _pickFile(TextEditingController targetCtrl, String title) async {
    final home = Platform.environment['HOME'] ?? '/tmp';
    final initialDir = targetCtrl.text.trim().isNotEmpty
        ? targetCtrl.text.trim()
        : '$home/Downloads/';
    final cleanEnv = Map<String, String>.from(Platform.environment)
      ..remove('LD_LIBRARY_PATH');
    final res = await Process.run(
      'zenity',
      [
        '--file-selection',
        '--title=$title',
        '--filename=$initialDir',
      ],
      environment: cleanEnv,
    );
    if (res.exitCode == 0) {
      final path = res.stdout.toString().trim();
      if (path.isNotEmpty) {
        setState(() => targetCtrl.text = path);
      }
    }
  }

  void _addExtraCredential(String typeKey) {
    if (!_enabledExtras.contains(typeKey)) {
      setState(() {
        _enabledExtras.add(typeKey);
      });
    }
  }

  void _removeExtraCredential(String typeKey) {
    setState(() {
      _enabledExtras.remove(typeKey);
    });
  }

  void _save() {
    if (_addressCtrl.text.trim().isEmpty || _userCtrl.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Informe o Address (IP/Domínio) e o Username.'),
          backgroundColor: Color(0xFFDC2626),
        ),
      );
      return;
    }

    final title = _nameCtrl.text.trim().isNotEmpty
        ? _nameCtrl.text.trim()
        : '${_userCtrl.text.trim()}@${_addressCtrl.text.trim()}';

    final cfg = SshHostConfig(
      id: widget.initialHost?.id ??
          DateTime.now().millisecondsSinceEpoch.toString(),
      name: title,
      group: _groupCtrl.text.trim().isEmpty ? 'Geral' : _groupCtrl.text.trim(),
      address: _addressCtrl.text.trim(),
      port: int.tryParse(_portCtrl.text.trim()) ?? 22,
      username: _userCtrl.text.trim(),
      password: _passwordCtrl.text,
      enabledExtras: _enabledExtras,
      privateKeyPath: _privateKeyPathCtrl.text.trim(),
      privateKeyContent: _privateKeyContentCtrl.text,
      passphrase: _passphraseCtrl.text,
      certificatePath: _certificatePathCtrl.text.trim(),
      fido2KeyPath: _fido2KeyPathCtrl.text.trim(),
      fido2Provider: _fido2ProviderCtrl.text.trim(),
      sshId: _sshIdCtrl.text.trim(),
      proxyJump: _proxyJumpCtrl.text.trim(),
      localForward: _localFwdCtrl.text.trim(),
      remoteForward: _remoteFwdCtrl.text.trim(),
      startupCommand: _startupCmdCtrl.text.trim(),
      keepAliveInterval: int.tryParse(_keepAliveCtrl.text.trim()) ?? 30,
      x11Forwarding: _x11Forwarding,
      compression: _compression,
    );

    Navigator.pop(context, cfg);
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: SizedBox(
        width: 660,
        height: 620,
        child: DefaultTabController(
          length: 2,
          child: Column(
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    colors: [Color(0xFF0A3D22), Color(0xFF15803D)],
                  ),
                  borderRadius: BorderRadius.only(
                    topLeft: Radius.circular(16),
                    topRight: Radius.circular(16),
                  ),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.dns_rounded, color: Colors.white),
                    const SizedBox(width: 10),
                    Text(
                      widget.initialHost == null
                          ? 'Novo Servidor SSH / SFTP'
                          : 'Editar Servidor SSH / SFTP',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      onPressed: () => Navigator.pop(context),
                      icon:
                          const Icon(Icons.close_rounded, color: Colors.white),
                    ),
                  ],
                ),
              ),
              const TabBar(
                tabs: [
                  Tab(text: 'Host & Credenciais (Password / + Key / FIDO2)'),
                  Tab(text: 'Túneis & Avançado'),
                ],
              ),
              Expanded(
                child: TabBarView(
                  children: [
                    _buildMainHostAndCredentialsTab(),
                    _buildAdvancedTab(),
                  ],
                ),
              ),
              const Divider(height: 1),
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Cancelar'),
                    ),
                    const SizedBox(width: 10),
                    ElevatedButton.icon(
                      onPressed: _save,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF15803D),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 12,
                        ),
                      ),
                      icon: const Icon(Icons.check_rounded, size: 18),
                      label: const Text(
                        'Salvar Host',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMainHostAndCredentialsTab() {
    final borderCol = widget.isDark
        ? const Color(0xFF26354D)
        : const Color(0xFFCBD5E1);

    return ListView(
      padding: const EdgeInsets.all(18),
      children: [
        // Row 1: Name & Group
        Row(
          children: [
            Expanded(
              flex: 2,
              child: TextField(
                controller: _nameCtrl,
                decoration: const InputDecoration(
                  labelText: 'Nome / Apelido do Servidor',
                  hintText: 'Ex: Servidor Web Produção',
                  prefixIcon: Icon(Icons.label_outline_rounded),
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: _groupCtrl,
                decoration: const InputDecoration(
                  labelText: 'Grupo / Tag',
                  hintText: 'Ex: Produção',
                  prefixIcon: Icon(Icons.folder_outlined),
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        // Row 2: Address & Port
        Row(
          children: [
            Expanded(
              flex: 3,
              child: TextField(
                controller: _addressCtrl,
                decoration: const InputDecoration(
                  labelText: 'Address (IP ou Domínio) *',
                  hintText: 'Ex: 192.168.1.100 ou servidor.empresa.com',
                  prefixIcon: Icon(Icons.language_rounded),
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: _portCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'SSH Porta *',
                  hintText: '22',
                  prefixIcon: Icon(Icons.numbers_rounded),
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        // Row 3: Username
        TextField(
          controller: _userCtrl,
          decoration: const InputDecoration(
            labelText: 'Username (Usuário SSH) *',
            hintText: 'Ex: root, ubuntu, ec2-user',
            prefixIcon: Icon(Icons.person_outline_rounded),
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
        const SizedBox(height: 14),
        // Row 4: Direct Password text field!
        TextField(
          controller: _passwordCtrl,
          obscureText: _obscurePassword,
          decoration: InputDecoration(
            labelText: 'Password (Digite a senha do SSH)',
            hintText: 'Digite a senha do servidor (se usar senha)',
            prefixIcon: const Icon(Icons.lock_outline_rounded),
            suffixIcon: IconButton(
              onPressed: () =>
                  setState(() => _obscurePassword = !_obscurePassword),
              tooltip: _obscurePassword ? 'Mostrar senha' : 'Ocultar senha',
              icon: Icon(
                _obscurePassword
                    ? Icons.visibility_outlined
                    : Icons.visibility_off_outlined,
              ),
            ),
            border: const OutlineInputBorder(),
            isDense: true,
          ),
        ),
        const SizedBox(height: 16),

        // Row 5: Second Field / "+" Button to add SSH ID, Key, Certificate, FIDO2
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: borderCol),
            color: widget.isDark
                ? const Color(0xFF0F172A)
                : const Color(0xFFF8FAFC),
          ),
          child: Row(
            children: [
              const Icon(Icons.vpn_key_rounded,
                  size: 19, color: Color(0xFF22C55E)),
              const SizedBox(width: 10),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Credenciais Adicionais (SSH ID, Key, Certificate, FIDO2)',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      'Clique no botão "+" para adicionar chaves ou certificados à conexão',
                      style: TextStyle(fontSize: 11.5, color: Colors.grey),
                    ),
                  ],
                ),
              ),
              PopupMenuButton<String>(
                tooltip: 'Adicionar credencial SSH',
                onSelected: _addExtraCredential,
                itemBuilder: (ctx) => const [
                  PopupMenuItem(
                    value: 'sshId',
                    child: ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.badge_outlined, color: Color(0xFF38BDF8)),
                      title: Text('SSH ID (Passkeys for SSH)'),
                    ),
                  ),
                  PopupMenuItem(
                    value: 'privateKey',
                    child: ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.key_rounded, color: Color(0xFF22C55E)),
                      title: Text('Key (Chave Privada .pem / .ppk / id_rsa)'),
                    ),
                  ),
                  PopupMenuItem(
                    value: 'certificate',
                    child: ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading:
                          Icon(Icons.verified_outlined, color: Color(0xFFF59E0B)),
                      title: Text('Certificate (Certificado SSH)'),
                    ),
                  ),
                  PopupMenuItem(
                    value: 'fido2',
                    child: ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.usb_rounded, color: Color(0xFFA855F7)),
                      title: Text('FIDO2 (Security Key)'),
                    ),
                  ),
                ],
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: const Color(0xFF15803D),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.add_rounded, color: Colors.white, size: 18),
                      SizedBox(width: 4),
                      Text(
                        'Adicionar',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 12.5,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),

        // Render dynamically added credential sections
        if (_enabledExtras.contains('sshId')) ...[
          const SizedBox(height: 12),
          _buildExtraSectionCard(
            title: 'SSH ID (Passkeys for SSH)',
            icon: Icons.badge_outlined,
            accent: const Color(0xFF38BDF8),
            onRemove: () => _removeExtraCredential('sshId'),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _sshIdCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Caminho do SSH ID / Passkey',
                      hintText: '/home/usuario/.ssh/id_ed25519',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: () =>
                      _pickFile(_sshIdCtrl, 'Selecionar SSH ID / Passkey'),
                  icon: const Icon(Icons.folder_open_rounded, size: 17),
                  label: const Text('Procurar'),
                ),
              ],
            ),
          ),
        ],

        if (_enabledExtras.contains('privateKey')) ...[
          const SizedBox(height: 12),
          _buildExtraSectionCard(
            title: 'Key (Chave Privada .pem / .ppk / id_rsa)',
            icon: Icons.key_rounded,
            accent: const Color(0xFF22C55E),
            onRemove: () => _removeExtraCredential('privateKey'),
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _privateKeyPathCtrl,
                        decoration: const InputDecoration(
                          labelText:
                              'Arquivo da Chave (.pem, .ppk, id_rsa, id_ed25519)',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton.icon(
                      onPressed: () => _pickFile(
                        _privateKeyPathCtrl,
                        'Selecionar Chave Privada (.pem, .ppk, id_rsa)',
                      ),
                      icon: const Icon(Icons.folder_open_rounded, size: 17),
                      label: const Text('Procurar'),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _passphraseCtrl,
                  obscureText: _obscurePassphrase,
                  decoration: InputDecoration(
                    labelText: 'Passphrase da Chave (Opcional)',
                    border: const OutlineInputBorder(),
                    isDense: true,
                    suffixIcon: IconButton(
                      onPressed: () => setState(
                          () => _obscurePassphrase = !_obscurePassphrase),
                      icon: Icon(_obscurePassphrase
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _privateKeyContentCtrl,
                  maxLines: 2,
                  style:
                      const TextStyle(fontFamily: 'monospace', fontSize: 11.5),
                  decoration: const InputDecoration(
                    labelText:
                        'Ou cole aqui o texto da Chave Privada (-----BEGIN OPENSSH PRIVATE KEY-----)',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ],
            ),
          ),
        ],

        if (_enabledExtras.contains('certificate')) ...[
          const SizedBox(height: 12),
          _buildExtraSectionCard(
            title: 'Certificate (Certificado SSH *-cert.pub)',
            icon: Icons.verified_outlined,
            accent: const Color(0xFFF59E0B),
            onRemove: () => _removeExtraCredential('certificate'),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _certificatePathCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Arquivo do Certificado (*-cert.pub)',
                      hintText: '/home/usuario/.ssh/id_ed25519-cert.pub',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: () => _pickFile(
                    _certificatePathCtrl,
                    'Selecionar Certificado SSH (*-cert.pub)',
                  ),
                  icon: const Icon(Icons.folder_open_rounded, size: 17),
                  label: const Text('Procurar'),
                ),
              ],
            ),
          ),
        ],

        if (_enabledExtras.contains('fido2')) ...[
          const SizedBox(height: 12),
          _buildExtraSectionCard(
            title: 'FIDO2 (Security Key / YubiKey)',
            icon: Icons.usb_rounded,
            accent: const Color(0xFFA855F7),
            onRemove: () => _removeExtraCredential('fido2'),
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _fido2KeyPathCtrl,
                        decoration: const InputDecoration(
                          labelText:
                              'Caminho da Chave FIDO2 (id_ed25519_sk / id_ecdsa_sk)',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton.icon(
                      onPressed: () => _pickFile(
                        _fido2KeyPathCtrl,
                        'Selecionar Chave FIDO2 (*_sk)',
                      ),
                      icon: const Icon(Icons.folder_open_rounded, size: 17),
                      label: const Text('Procurar'),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _fido2ProviderCtrl,
                  decoration: const InputDecoration(
                    labelText: 'SecurityKeyProvider (Padrão: internal)',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildExtraSectionCard({
    required String title,
    required IconData icon,
    required Color accent,
    required VoidCallback onRemove,
    required Widget child,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: accent.withValues(alpha: 0.55)),
        color: accent.withValues(alpha: 0.05),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(icon, size: 17, color: accent),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w800,
                    color: accent,
                  ),
                ),
              ),
              InkWell(
                onTap: onRemove,
                child: const Padding(
                  padding: EdgeInsets.all(2.0),
                  child: Icon(Icons.close_rounded,
                      size: 17, color: Color(0xFFEF4444)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          child,
        ],
      ),
    );
  }

  Widget _buildAdvancedTab() {
    return ListView(
      padding: const EdgeInsets.all(18),
      children: [
        TextField(
          controller: _proxyJumpCtrl,
          decoration: const InputDecoration(
            labelText: 'ProxyJump / Bastion Host (-J)',
            hintText: 'Ex: user@bastion.empresa.com:22',
            prefixIcon: Icon(Icons.swap_horiz_rounded),
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _localFwdCtrl,
                decoration: const InputDecoration(
                  labelText: 'Port Forward Local (-L)',
                  hintText: 'Ex: 8080:localhost:80',
                  prefixIcon: Icon(Icons.call_received_rounded),
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: _remoteFwdCtrl,
                decoration: const InputDecoration(
                  labelText: 'Port Forward Remoto (-R)',
                  hintText: 'Ex: 9000:localhost:3000',
                  prefixIcon: Icon(Icons.call_made_rounded),
                  border: OutlineInputBorder(),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            Expanded(
              flex: 2,
              child: TextField(
                controller: _startupCmdCtrl,
                decoration: const InputDecoration(
                  labelText: 'Comando Inicial ao Conectar (Opcional)',
                  hintText: 'Ex: cd /var/www && ls -la',
                  prefixIcon: Icon(Icons.play_arrow_rounded),
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: _keepAliveCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'KeepAlive (seg)',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        SwitchListTile(
          value: _x11Forwarding,
          onChanged: (v) => setState(() => _x11Forwarding = v),
          title: const Text('X11 Forwarding (-X)'),
          subtitle: const Text('Redirecionar janelas gráficas X11 via SSH'),
          contentPadding: EdgeInsets.zero,
        ),
        SwitchListTile(
          value: _compression,
          onChanged: (v) => setState(() => _compression = v),
          title: const Text('Compressão de Dados (-C)'),
          subtitle: const Text('Comprimir tráfego SSH/SFTP em conexões lentas'),
          contentPadding: EdgeInsets.zero,
        ),
      ],
    );
  }
}
