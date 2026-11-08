import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_svg/flutter_svg.dart';

import '../colors.dart';

/// Home screen world map.
///
///   disconnected            whole world in grey
///   connecting              zoom on the country, filled orange, pulsing
///   connected/disconnecting zoom on the country, filled green
///
/// Small countries (Netherlands, Singapore...) also get a dot, otherwise they
/// would be invisible. Map data: assets/maps/world_map.json, generated from
/// Natural Earth (public domain) with ISO country codes, so any country the
/// backend adds later works without an app update.
class WorldMapView extends StatefulWidget {
  /// disconnected | connecting | connected | disconnecting
  final String connectionState;

  /// ISO code of the country to highlight ("FR"), or null (world view)
  final String? countryCode;

  const WorldMapView({super.key, required this.connectionState, required this.countryCode});

  @override
  State<WorldMapView> createState() => _WorldMapViewState();
}

class _WorldMapViewState extends State<WorldMapView> with SingleTickerProviderStateMixin {
  static const Color _grey = Color(0xFFD9DDE3);
  static const Color _green = Color(0xFF3DBE5A);

  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  @override
  void initState() {
    super.initState();
    _updatePulse();
  }

  @override
  void didUpdateWidget(covariant WorldMapView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.connectionState != widget.connectionState) _updatePulse();
  }

  void _updatePulse() {
    if (widget.connectionState == 'connecting') {
      _pulse.repeat(reverse: true);
    } else {
      _pulse.stop();
      _pulse.value = 1;
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  bool get _highlighted => widget.connectionState != 'disconnected' && widget.countryCode != null;

  Color get _accent => widget.connectionState == 'connecting' ? MyColors.myOrange : _green;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<WorldMapData>(
      future: WorldMapData.load(),
      builder: (context, snapshot) {
        final data = snapshot.data;
        return ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: AspectRatio(
            aspectRatio: 2,
            child: data == null ? const SizedBox.shrink() : _buildMap(data),
          ),
        );
      },
    );
  }

  Widget _buildMap(WorldMapData data) {
    final code = _highlighted ? widget.countryCode!.toUpperCase() : null;
    final target = code != null ? data.zoomRect(code) : data.fullRect;
    final overlay = code != null ? data.overlaySvg(code, _accent) : null;

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        return ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: TweenAnimationBuilder<Rect?>(
            tween: RectTween(end: target),
            duration: const Duration(milliseconds: 650),
            curve: Curves.easeInOutCubic,
            builder: (context, rect, child) {
              final view = rect ?? target;
              final scale = width / view.width;
              return Transform(
                transform: Matrix4.identity()
                  ..scaleByDouble(scale, scale, 1, 1)
                  ..translateByDouble(-view.left, -view.top, 0, 1),
                child: child,
              );
            },
            child: OverflowBox(
              alignment: Alignment.topLeft,
              minWidth: data.width,
              maxWidth: data.width,
              minHeight: data.height,
              maxHeight: data.height,
              child: Stack(
                children: [
                  SvgPicture.string(data.baseSvg(_grey), width: data.width, height: data.height),
                  if (overlay != null)
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 350),
                      child: FadeTransition(
                        key: ValueKey('$code-${_accent.toARGB32()}'),
                        opacity: Tween<double>(begin: 0.45, end: 1).animate(_pulse),
                        child: SvgPicture.string(overlay, width: data.width, height: data.height),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _MapCountry {
  final String path;
  final Rect box;
  final bool small;

  const _MapCountry(this.path, this.box, this.small);
}

/// Parsed assets/maps/world_map.json (loaded once).
class WorldMapData {
  final double width;
  final double height;
  final Map<String, _MapCountry> _countries;
  final Map<String, Offset> _points;
  final List<String> _otherPaths;
  final Map<int, String> _baseCache = {};

  WorldMapData._(this.width, this.height, this._countries, this._points, this._otherPaths);

  static Future<WorldMapData>? _future;

  static Future<WorldMapData> load() => _future ??= _load();

  static Future<WorldMapData> _load() async {
    final raw = json.decode(await rootBundle.loadString('assets/maps/world_map.json')) as Map<String, dynamic>;

    final countries = <String, _MapCountry>{};
    (raw['countries'] as Map<String, dynamic>).forEach((code, value) {
      final c = value as Map<String, dynamic>;
      final box = (c['box'] as List).map((v) => (v as num).toDouble()).toList();
      countries[code] = _MapCountry(
        c['d'] as String,
        Rect.fromLTWH(box[0], box[1], box[2], box[3]),
        c['small'] == true,
      );
    });

    final points = <String, Offset>{};
    (raw['points'] as Map<String, dynamic>).forEach((code, value) {
      final p = (value as List).map((v) => (v as num).toDouble()).toList();
      points[code] = Offset(p[0], p[1]);
    });

    return WorldMapData._(
      (raw['w'] as num).toDouble(),
      (raw['h'] as num).toDouble(),
      countries,
      points,
      (raw['other'] as List).cast<String>(),
    );
  }

  Rect get fullRect => Rect.fromLTWH(0, 0, width, height);

  String _hex(Color color) =>
      '#${(color.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

  /// Every country in one colour (built once per colour)
  String baseSvg(Color fill) {
    return _baseCache.putIfAbsent(fill.toARGB32(), () {
      final buffer = StringBuffer()
        ..write('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 $width $height" '
            'width="$width" height="$height">')
        ..write('<g fill="${_hex(fill)}" stroke="#FFFFFF" stroke-width="0.5">');
      for (final country in _countries.values) {
        buffer.write('<path d="${country.path}"/>');
      }
      for (final path in _otherPaths) {
        buffer.write('<path d="$path"/>');
      }
      buffer.write('</g></svg>');
      return buffer.toString();
    });
  }

  /// The highlighted country (and a dot for small ones), same coordinates as the base
  String? overlaySvg(String code, Color color) {
    final country = _countries[code];
    final point = _points[code];
    if (country == null && point == null) return null;

    final hex = _hex(color);
    final buffer = StringBuffer()
      ..write('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 $width $height" '
          'width="$width" height="$height">');
    if (country != null) {
      buffer.write('<path d="${country.path}" fill="$hex" stroke="#FFFFFF" stroke-width="0.5"/>');
    }
    if (country == null || country.small) {
      final center = country?.box.center ?? point!;
      buffer
        ..write('<circle cx="${center.dx}" cy="${center.dy}" r="9" fill="$hex" fill-opacity="0.25"/>')
        ..write('<circle cx="${center.dx}" cy="${center.dy}" r="4.5" fill="$hex" '
            'stroke="#FFFFFF" stroke-width="1.5"/>');
    }
    buffer.write('</svg>');
    return buffer.toString();
  }

  /// Part of the map to show for a country: about 2.4x zoom, wider for big
  /// countries (USA, Canada) so they fit, kept inside the map.
  Rect zoomRect(String code) {
    final country = _countries[code];
    final point = _points[code];
    if (country == null && point == null) return fullRect;

    final box = country?.box ?? Rect.fromCenter(center: point!, width: 1, height: 1);
    var w = math.max(width / 3.5, math.max(box.width * 1.8, box.height * 1.8 * (width / height)));
    w = math.min(w, width);
    final h = w * height / width;

    final left = (box.center.dx - w / 2).clamp(0.0, width - w);
    final top = (box.center.dy - h / 2).clamp(0.0, height - h);
    return Rect.fromLTWH(left, top, w, h);
  }
}
