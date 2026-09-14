// HorizonDesk — écran de l'app sur tablette (maquette validée par Hugo le 14/09,
// mockups/horizondesk_app_v1.html du dépôt Horizon).
//
// L'opérateur n'ouvre HorizonDesk qu'à l'installation ou quand ça coince : un seul écran
// dit si le poste est prêt, ce qui manque, et ce qui se passe pendant une assistance.
// Les onglets RustDesk d'origine restent derrière « Réglages avancés » (support).
// Responsive : deux colonnes dès 720 px de large, une seule en dessous (bornes, petits
// terminaux), bandeau compacté sous 480 px.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../models/platform_model.dart';

class HzColors {
  static const bg = Color(0xFFEEF0F4);
  static const panel = Color(0xFFFFFFFF);
  static const border = Color(0xFFE1E4EA);
  static const text = Color(0xFF1B1E27);
  static const muted = Color(0xFF5B6172);
  static const faint = Color(0xFF9AA0AF);
  static const accent = Color(0xFF0EA371);
  static const accentDark = Color(0xFF0B8A60);
  static const warning = Color(0xFFE08B00);
  static const warningText = Color(0xFF7A5600);
  static const warningBg = Color(0xFFFFF8E8);
  static const warningBorder = Color(0xFFF0DCAE);
  static const danger = Color(0xFFDF3641);
  static const dangerText = Color(0xFF8A1C24);
  static const dangerBg = Color(0xFFFDEEEE);
  static const dangerBorder = Color(0xFFF3C2C5);
  static const idle = Color(0xFFB7BCC8);
  static const heroA = Color(0xFF121A2B);
  static const heroB = Color(0xFF1D2740);
  static const heroC = Color(0xFF16324A);
  static const heroMuted = Color(0xFF9FB0D0);
}

enum _Level { ok, warn, bad, idle }

class HorizonDeskPage extends StatefulWidget {
  final VoidCallback onAdvanced;
  const HorizonDeskPage({Key? key, required this.onAdvanced}) : super(key: key);

  @override
  State<HorizonDeskPage> createState() => _HorizonDeskPageState();
}

class _HorizonDeskPageState extends State<HorizonDeskPage> {
  Map<String, dynamic> _st = {};
  String _id = '';
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final raw = await platformFFI.invokeMethod('horizon_status');
      String id = '';
      try {
        id = await bind.mainGetMyId();
      } catch (_) {}
      if (id.isNotEmpty) {
        // Déposé pour le pont : Horizon POS peut remonter l'ID avant la 1ʳᵉ assistance.
        platformFFI.invokeMethod('horizon_note_id', id);
      }
      if (!mounted) return;
      setState(() {
        _st = raw is Map ? Map<String, dynamic>.from(raw) : {};
        _id = id.isNotEmpty ? id : (_st['id'] as String? ?? '');
      });
    } catch (_) {}
  }

  void _open(String target) => platformFFI.invokeMethod('horizon_open', target);

  bool get _callerInstalled => _st['caller_installed'] == true;
  int get _lastContactAgo => (_st['last_contact_ms_ago'] as num?)?.toInt() ?? -1;
  bool get _linked => _callerInstalled && _lastContactAgo >= 0 && _lastContactAgo < 60000;
  bool get _input => _st['input_enabled'] == true;
  bool get _sharing => _st['sharing'] == true;
  bool get _armed => _st['armed'] == true;
  bool get _control => _st['control'] == true;

  List<Map<String, dynamic>> get _connections {
    try {
      final v = jsonDecode(_st['connections'] as String? ?? '[]');
      return (v as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
    } catch (_) {
      return [];
    }
  }

  String _formatId(String id) {
    if (id.length != 10) return id;
    return '${id.substring(0, 3)} ${id.substring(3, 6)} ${id.substring(6)}';
  }

  String _ago(int ms) {
    final s = (ms / 1000).round();
    if (s < 60) return 'il y a $s s';
    if (s < 3600) return 'il y a ${(s / 60).round()} min';
    return 'il y a ${(s / 3600).round()} h';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: HzColors.bg,
      body: LayoutBuilder(builder: (context, c) {
        final wide = c.maxWidth >= 720;
        final compactHero = c.maxWidth < 480;
        final left = _leftColumn();
        final right = _rightColumn();
        return Column(children: [
          _hero(compactHero),
          Expanded(
            child: wide
                ? Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Expanded(flex: 5, child: SingleChildScrollView(child: left)),
                      const SizedBox(width: 12),
                      Expanded(flex: 4, child: SingleChildScrollView(child: right)),
                    ]),
                  )
                : ListView(padding: const EdgeInsets.all(12), children: [
                    left,
                    const SizedBox(height: 12),
                    right,
                  ]),
          ),
        ]);
      }),
    );
  }

  Widget _hero(bool compact) {
    final idText = _id.isEmpty ? '—' : _formatId(_id);
    final title = Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: const [
      Text('HorizonDesk', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w800)),
      SizedBox(height: 2),
      Text('Support à distance Parsight', style: TextStyle(color: HzColors.heroMuted, fontSize: 12)),
    ]);
    final id = Column(
      crossAxisAlignment: compact ? CrossAxisAlignment.start : CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text('ID DE CE POSTE',
            style: TextStyle(color: HzColors.heroMuted, fontSize: 10.5, letterSpacing: 1.1, fontWeight: FontWeight.w600)),
        const SizedBox(height: 2),
        SelectableText(idText,
            style: const TextStyle(
                color: Colors.white, fontSize: 24, fontWeight: FontWeight.w700, letterSpacing: 1.5,
                fontFeatures: [FontFeature.tabularFigures()], fontFamily: 'monospace')),
      ],
    );
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(colors: [HzColors.heroA, HzColors.heroB, HzColors.heroC]),
      ),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: compact
              ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [_peaks(), const SizedBox(width: 10), Expanded(child: title)]),
                  const SizedBox(height: 10),
                  id,
                ])
              : Row(children: [_peaks(), const SizedBox(width: 12), Expanded(child: title), id]),
        ),
      ),
    );
  }

  Widget _peaks() => SizedBox(width: 62, height: 38, child: SvgPicture.asset('assets/horizon_peaks.svg'));

  // ------------------------------------------------------------------ colonnes

  Widget _leftColumn() {
    final children = <Widget>[];
    if (!_callerInstalled && _st.isNotEmpty) {
      children.add(_alert(
          'Aucune assistance possible sur ce poste.',
          "HorizonDesk n'accepte que les assistances autorisées depuis Horizon POS, "
              'et Horizon POS est absent ou trop ancien.',
          HzColors.dangerBg, HzColors.dangerBorder, HzColors.dangerText));
      children.add(const SizedBox(height: 10));
    } else if (_armed) {
      children.add(_liveBlock());
      children.add(const SizedBox(height: 10));
    }
    children.add(_card('CE POSTE', [
      _row(
        _callerInstalled ? (_linked ? _Level.ok : _Level.warn) : _Level.bad,
        'Relié à Horizon POS',
        _callerInstalled
            ? (_linked
                ? 'Seul Horizon POS peut autoriser une assistance'
                : (_lastContactAgo < 0
                    ? 'Pas encore de contact — ouvrez Horizon POS'
                    : 'Dernier contact ${_ago(_lastContactAgo)} — ouvrez Horizon POS'))
            : 'Horizon POS introuvable sur ce poste',
        _callerInstalled ? (_linked ? 'OK' : 'À vérifier') : 'Non',
      ),
      _row(
        _input ? _Level.ok : _Level.warn,
        'Saisie à distance',
        _input
            ? "Le technicien pourra cliquer si vous l'autorisez"
            : 'Sans elle, le technicien voit mais ne peut pas vous dépanner',
        _input ? 'Autorisée' : 'À activer',
      ),
      _row(
        _sharing ? _Level.ok : _Level.idle,
        "Partage d'écran",
        _sharing ? "Tout l'écran" : 'Démarre quand vous acceptez une assistance dans Horizon POS',
        _sharing ? 'Actif' : 'En attente',
      ),
    ]));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children);
  }

  Widget _rightColumn() {
    if (_st.isNotEmpty && !_callerInstalled) {
      return _card('QUE FAIRE', [
        _note('Installer ou mettre à jour Horizon POS, puis revenir ici. Besoin d\'aide : support@parsight.fr.'),
        const SizedBox(height: 10),
        _button('Réglages avancés', _Btn.link, widget.onAdvanced),
      ]);
    }
    if (_armed) {
      return _card('ARRÊTER', [
        _note("L'assistance se pilote depuis Horizon POS : c'est là que se trouvent "
            '« Reprendre la main » et « Interrompre l\'assistance ».'),
        const SizedBox(height: 12),
        _button('Revenir à Horizon POS', _Btn.primary, () => _open('horizonpos')),
      ]);
    }
    if (!_input) {
      return _card("ACTIVER LA SAISIE À DISTANCE", [
        _step(1, 'Touchez le bouton ci-dessous, puis HorizonDesk Input → Activer.'),
        _step(2, 'Si Android refuse (« paramètre restreint ») : Infos de l\'app → ⋮ → '
            'Autoriser les paramètres restreints, puis recommencez.'),
        const SizedBox(height: 10),
        _button("Ouvrir les réglages d'accessibilité", _Btn.warn, () => _open('accessibility')),
        const SizedBox(height: 6),
        _button("Infos de l'app HorizonDesk", _Btn.link, () => _open('app_info')),
      ]);
    }
    return _card('TOUT EST PRÊT', [
      _note("Rien à faire ici. Pour être aidé : Horizon POS → Aide & support → Demander de l'aide."),
      const SizedBox(height: 12),
      _button('Ouvrir Horizon POS', _Btn.primary, () => _open('horizonpos')),
      const SizedBox(height: 4),
      _button('Réglages avancés', _Btn.link, widget.onAdvanced),
    ]);
  }

  Widget _liveBlock() {
    final cx = _connections;
    final control = _control;
    final peer = cx.isNotEmpty ? cx.first['peer_id'] as String? ?? '' : '';
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: control ? HzColors.dangerBg : HzColors.warningBg,
        border: Border.all(color: control ? HzColors.dangerBorder : HzColors.warningBorder),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(control ? 'Assistance en cours — prise de contrôle' : 'Assistance en cours — vue seule',
            style: TextStyle(
                fontSize: 15, fontWeight: FontWeight.w800,
                color: control ? HzColors.dangerText : HzColors.warningText)),
        const SizedBox(height: 4),
        Text(
            control
                ? 'Le technicien pilote cet écran. Encaissement suspendu.'
                : cx.isEmpty
                    ? "Assistance autorisée. En attente de la connexion du technicien."
                    : 'Parsight voit l\'écran. Clavier et souris coupés. La caisse continue de vendre.',
            style: const TextStyle(fontSize: 13, color: HzColors.text, height: 1.4)),
        if (peer.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text('Poste technicien $peer',
              style: const TextStyle(fontSize: 12, fontFamily: 'monospace', color: HzColors.muted)),
        ],
      ]),
    );
  }

  // ------------------------------------------------------------------ briques

  Widget _card(String title, List<Widget> children) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: HzColors.panel,
        border: Border.all(color: HzColors.border),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(title,
            style: const TextStyle(fontSize: 11, letterSpacing: 1.1, fontWeight: FontWeight.w800, color: HzColors.faint)),
        const SizedBox(height: 8),
        ...children,
      ]),
    );
  }

  Widget _row(_Level level, String label, String detail, String state) {
    final color = {
      _Level.ok: HzColors.accent,
      _Level.warn: HzColors.warning,
      _Level.bad: HzColors.danger,
      _Level.idle: HzColors.idle,
    }[level]!;
    final stateColor = {
      _Level.ok: HzColors.accentDark,
      _Level.warn: HzColors.warningText,
      _Level.bad: HzColors.dangerText,
      _Level.idle: HzColors.muted,
    }[level]!;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: const BoxDecoration(border: Border(top: BorderSide(color: Color(0xFFF0F1F4)))),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.only(top: 5),
          child: Container(width: 10, height: 10, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: HzColors.text)),
            const SizedBox(height: 2),
            Text(detail, style: const TextStyle(fontSize: 12, color: HzColors.muted, height: 1.35)),
          ]),
        ),
        const SizedBox(width: 8),
        Text(state, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: stateColor)),
      ]),
    );
  }

  Widget _note(String text) =>
      Text(text, style: const TextStyle(fontSize: 13, color: HzColors.muted, height: 1.45));

  Widget _step(int n, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('$n.', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: HzColors.accentDark)),
        const SizedBox(width: 8),
        Expanded(child: Text(text, style: const TextStyle(fontSize: 13, color: HzColors.text, height: 1.45))),
      ]),
    );
  }

  Widget _alert(String title, String text, Color bg, Color border, Color fg) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: bg, border: Border.all(color: border), borderRadius: BorderRadius.circular(12)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: fg)),
        const SizedBox(height: 4),
        Text(text, style: TextStyle(fontSize: 13, color: fg, height: 1.4)),
      ]),
    );
  }

  Widget _button(String label, _Btn kind, VoidCallback onTap) {
    switch (kind) {
      case _Btn.primary:
        return FilledButton(
          style: FilledButton.styleFrom(
              backgroundColor: HzColors.accentDark,
              foregroundColor: Colors.white,
              minimumSize: const Size.fromHeight(46),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
          onPressed: onTap,
          child: Text(label, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
        );
      case _Btn.warn:
        return OutlinedButton(
          style: OutlinedButton.styleFrom(
              backgroundColor: HzColors.warningBg,
              foregroundColor: HzColors.warningText,
              side: const BorderSide(color: HzColors.warningBorder),
              minimumSize: const Size.fromHeight(46),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
          onPressed: onTap,
          child: Text(label, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
        );
      case _Btn.link:
        return TextButton(
          style: TextButton.styleFrom(foregroundColor: HzColors.muted, minimumSize: const Size.fromHeight(40)),
          onPressed: onTap,
          child: Text(label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        );
    }
  }
}

enum _Btn { primary, warn, link }
