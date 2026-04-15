import 'dart:convert';

import '../../domain/entities/lottie_animation.dart';

class LottieSerializer {
  const LottieSerializer();

  Map<String, dynamic> toMap(LottieDoc doc) => {
    'v': doc.version,
    'fr': doc.frameRate,
    'ip': doc.inPoint,
    'op': doc.outPoint,
    'w': doc.width.toInt(),
    'h': doc.height.toInt(),
    'nm': 'anim_svg',
    'ddd': 0,
    'assets': doc.assets.map(_assetMap).toList(),
    'layers': doc.layers.map(_layerMap).toList(),
  };

  String toJson(LottieDoc doc) => json.encode(toMap(doc));

  Map<String, dynamic> _assetMap(LottieAsset a) => {
    'id': a.id,
    'w': a.width,
    'h': a.height,
    'u': '',
    'p': a.dataUri,
    'e': 1,
  };

  Map<String, dynamic> _layerMap(LottieLayer l) {
    switch (l) {
      case LottieImageLayer():
        return {
          'ddd': 0,
          'ind': l.index,
          'ty': 2,
          'nm': l.name,
          'refId': l.refId,
          'sr': 1,
          'ks': _transformMap(l.transform),
          'ao': 0,
          'ip': l.inPoint,
          'op': l.outPoint,
          'st': 0,
          'bm': 0,
          if (l.width != null) 'w': l.width,
          if (l.height != null) 'h': l.height,
          if (l.parent != null) 'parent': l.parent,
          if (l.td != null) 'td': l.td,
          if (l.tt != null) 'tt': l.tt,
          if (l.effects.isNotEmpty)
            'ef': [for (final e in l.effects) _effectMap(e)],
        };
      case LottieShapeLayer():
        return {
          'ddd': 0,
          'ind': l.index,
          'ty': 4,
          'nm': l.name,
          'sr': 1,
          'ks': _transformMap(l.transform),
          'ao': 0,
          'shapes': [_shapeGroup(l.shapes)],
          'ip': l.inPoint,
          'op': l.outPoint,
          'st': 0,
          'bm': 0,
          if (l.parent != null) 'parent': l.parent,
          if (l.td != null) 'td': l.td,
          if (l.tt != null) 'tt': l.tt,
          if (l.effects.isNotEmpty)
            'ef': [for (final e in l.effects) _effectMap(e)],
        };
      case LottieNullLayer():
        return {
          'ddd': 0,
          'ind': l.index,
          'ty': 3,
          'nm': l.name,
          'sr': 1,
          'ks': _transformMap(l.transform),
          'ao': 0,
          'ip': l.inPoint,
          'op': l.outPoint,
          'st': 0,
          'bm': 0,
          if (l.parent != null) 'parent': l.parent,
          if (l.td != null) 'td': l.td,
          if (l.tt != null) 'tt': l.tt,
        };
    }
  }

  Map<String, dynamic> _effectMap(LottieEffect e) {
    switch (e) {
      case LottieBlurEffect():
        return {
          'ty': 29,
          'nm': 'Gaussian Blur',
          'np': 3,
          'mn': 'ADBE Gaussian Blur 2',
          'ef': [
            {
              'ty': 0,
              'nm': 'Blurriness',
              'mn': 'ADBE Gaussian Blur 2-0001',
              'v': _scalarProp(e.blurriness),
            },
            {
              'ty': 7,
              'nm': 'Blur Dimensions',
              'mn': 'ADBE Gaussian Blur 2-0002',
              'v': {'a': 0, 'k': 1},
            },
            {
              'ty': 7,
              'nm': 'Repeat Edge Pixels',
              'mn': 'ADBE Gaussian Blur 2-0003',
              'v': {'a': 0, 'k': 0},
            },
          ],
        };
      case LottieBrightnessEffect():
        return {
          'ty': 22,
          'nm': 'Brightness & Contrast',
          'np': 3,
          'mn': 'ADBE Brightness & Contrast 2',
          'ef': [
            {
              'ty': 0,
              'nm': 'Brightness',
              'mn': 'ADBE Brightness & Contrast 2-0001',
              'v': _scalarProp(e.brightness),
            },
            {
              'ty': 0,
              'nm': 'Contrast',
              'mn': 'ADBE Brightness & Contrast 2-0002',
              'v': {'a': 0, 'k': 0},
            },
            {
              'ty': 7,
              'nm': 'Use Legacy',
              'mn': 'ADBE Brightness & Contrast 2-0003',
              'v': {'a': 0, 'k': 0},
            },
          ],
        };
      case LottieHueSaturationEffect():
        return {
          'ty': 19,
          'nm': 'Hue/Saturation',
          'np': 9,
          'mn': 'ADBE HUE SATURATION',
          'ef': [
            {
              'ty': 7,
              'nm': 'Channel Control',
              'mn': 'ADBE HUE SATURATION-0001',
              'v': {'a': 0, 'k': 0},
            },
            {
              'ty': 0,
              'nm': 'Master Hue',
              'mn': 'ADBE HUE SATURATION-0002',
              'v': {'a': 0, 'k': 0},
            },
            {
              'ty': 0,
              'nm': 'Master Saturation',
              'mn': 'ADBE HUE SATURATION-0003',
              'v': _scalarProp(e.masterSaturation),
            },
            {
              'ty': 0,
              'nm': 'Master Lightness',
              'mn': 'ADBE HUE SATURATION-0004',
              'v': {'a': 0, 'k': 0},
            },
            {
              'ty': 7,
              'nm': 'Colorize',
              'mn': 'ADBE HUE SATURATION-0005',
              'v': {'a': 0, 'k': 0},
            },
          ],
        };
    }
  }

  Map<String, dynamic> _shapeGroup(List<LottieShapeItem> items) => {
    'ty': 'gr',
    'it': [
      for (final it in items) _shapeItem(it),
      _groupTransform(),
    ],
  };

  Map<String, dynamic> _shapeItem(LottieShapeItem it) {
    switch (it) {
      case LottieShapeGeometry():
        switch (it.kind) {
          case LottieShapeKind.path:
            final kfs = it.pathKeyframes;
            if (kfs == null) {
              return {
                'ty': 'sh',
                'ks': {
                  'a': 0,
                  'k': {
                    'i': it.inTangents,
                    'o': it.outTangents,
                    'v': it.vertices,
                    'c': it.closed,
                  },
                },
              };
            }
            return {
              'ty': 'sh',
              'ks': {
                'a': 1,
                'k': [
                  for (var i = 0; i < kfs.length; i++)
                    {
                      't': kfs[i].time,
                      's': [
                        {
                          'i': kfs[i].inTangents,
                          'o': kfs[i].outTangents,
                          'v': kfs[i].vertices,
                          'c': kfs[i].closed,
                        }
                      ],
                      if (kfs[i].hold) 'h': 1,
                      if (kfs[i].bezierOut != null)
                        'o': {
                          'x': [kfs[i].bezierOut!.x],
                          'y': [kfs[i].bezierOut!.y],
                        },
                      if (kfs[i].bezierIn != null)
                        'i': {
                          'x': [kfs[i].bezierIn!.x],
                          'y': [kfs[i].bezierIn!.y],
                        },
                    },
                ],
              },
            };
          case LottieShapeKind.rect:
            return {
              'ty': 'rc',
              'p': {'a': 0, 'k': it.rectPosition},
              's': {'a': 0, 'k': it.rectSize},
              'r': {'a': 0, 'k': it.rectRoundness},
            };
          case LottieShapeKind.ellipse:
            return {
              'ty': 'el',
              'p': {'a': 0, 'k': it.ellipsePosition},
              's': {'a': 0, 'k': it.ellipseSize},
            };
        }
      case LottieShapeFill():
        return {
          'ty': 'fl',
          'c': {'a': 0, 'k': it.color},
          'o': {'a': 0, 'k': it.opacity},
          'r': 1,
          'bm': 0,
        };
      case LottieShapeGradientFill():
        return _gradientFill(it);
      case LottieShapeStroke():
        return {
          'ty': 'st',
          'c': {'a': 0, 'k': it.color},
          'o': {'a': 0, 'k': it.opacity},
          'w': {'a': 0, 'k': it.width},
          'lc': it.lineCap,
          'lj': it.lineJoin,
          'ml': it.miterLimit,
          'bm': 0,
        };
      case LottieShapeTrimPath():
        return {
          'ty': 'tm',
          's': _scalarProp(it.start),
          'e': _scalarProp(it.end),
          'o': _scalarProp(it.offset),
          'm': 1,
        };
    }
  }

  Map<String, dynamic> _gradientFill(LottieShapeGradientFill g) {
    final Map<String, dynamic> gk;
    switch (g.stops) {
      case LottieGradientStopsStatic(values: final v):
        gk = {'a': 0, 'k': v};
      case LottieGradientStopsAnimated(keyframes: final kfs):
        gk = {
          'a': 1,
          'k': [
            for (final kf in kfs)
              {
                't': kf.time,
                's': kf.values,
                if (kf.hold) 'h': 1,
              },
          ],
        };
    }
    return {
      'ty': 'gf',
      'o': {'a': 0, 'k': g.opacity},
      'r': 1,
      'bm': 0,
      't': g.kind == LottieGradientKind.radial ? 2 : 1,
      'g': {'p': g.colorStopCount, 'k': gk},
      's': {'a': 0, 'k': g.startPoint},
      'e': {'a': 0, 'k': g.endPoint},
    };
  }

  /// Every Lottie shape group requires its own `tr` transform (identity when
  /// we don't have anything special to apply — the layer-level transform in
  /// `ks` does the work).
  Map<String, dynamic> _groupTransform() => {
    'ty': 'tr',
    'a': {'a': 0, 'k': [0, 0]},
    'p': {'a': 0, 'k': [0, 0]},
    's': {'a': 0, 'k': [100, 100]},
    'r': {'a': 0, 'k': 0},
    'o': {'a': 0, 'k': 100},
    'sk': {'a': 0, 'k': 0},
    'sa': {'a': 0, 'k': 0},
  };

  Map<String, dynamic> _transformMap(LottieTransform t) => {
    'a': _vectorProp(t.anchor),
    'p': _vectorProp(t.position),
    's': _vectorProp(t.scale),
    'r': _scalarProp(t.rotation),
    'o': _scalarProp(t.opacity),
  };

  Map<String, dynamic> _vectorProp(LottieVectorProp p) {
    switch (p) {
      case LottieVectorStatic(value: final v):
        return {'a': 0, 'k': v};
      case LottieVectorAnimated(keyframes: final kfs):
        return {'a': 1, 'k': kfs.map(_vectorKeyframe).toList()};
    }
  }

  Map<String, dynamic> _scalarProp(LottieScalarProp p) {
    switch (p) {
      case LottieScalarStatic(value: final v):
        return {'a': 0, 'k': v};
      case LottieScalarAnimated(keyframes: final kfs):
        return {'a': 1, 'k': kfs.map(_scalarKeyframe).toList()};
    }
  }

  Map<String, dynamic> _vectorKeyframe(LottieVectorKeyframe k) {
    final map = <String, dynamic>{'t': k.time, 's': k.start};
    if (k.hold) map['h'] = 1;
    if (k.bezierIn != null) map['i'] = _handleMap(k.bezierIn!);
    if (k.bezierOut != null) map['o'] = _handleMap(k.bezierOut!);
    return map;
  }

  Map<String, dynamic> _scalarKeyframe(LottieScalarKeyframe k) {
    final map = <String, dynamic>{
      't': k.time,
      's': [k.start],
    };
    if (k.hold) map['h'] = 1;
    if (k.bezierIn != null) map['i'] = _handleMap(k.bezierIn!);
    if (k.bezierOut != null) map['o'] = _handleMap(k.bezierOut!);
    return map;
  }

  Map<String, dynamic> _handleMap(BezierHandle h) => {
    'x': [h.x],
    'y': [h.y],
  };
}
