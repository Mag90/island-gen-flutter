import 'dart:async';
import 'package:island_gen_flutter/features/editor/providers/global_settings_provider/global_settings_state_provider.dart';
import 'package:island_gen_flutter/features/heightmap_generator/heightmap_generator.dart';
import 'package:island_gen_flutter/models/layer.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'package:island_gen_flutter/generated/features/editor/providers/layer_provider/layer_provider.g.dart';

@Riverpod(keepAlive: true)
class LayerController extends _$LayerController {
  Timer? _debounceTimer;

  @override
  Layer build(String layerId) {
    print('LayerController build: $layerId');
    ref.listen(globalSettingsProvider, (previous, next) {
      if (previous?.resolution != next.resolution) {
        generateHeightmap();
      }
    });

    final layer = Layer(id: layerId);
    Future(() => generateHeightmap());
    return layer;
  }

  void destroy() {
    _debounceTimer?.cancel();
    ref.invalidateSelf();
  }

  void generateHeightmap() async {
    final globalSettings = ref.read(globalSettingsProvider);
    final resolution = globalSettings.resolution;
    final heightmap = await HeightmapGenerator.noise(
      resolution.width.toInt(),
      resolution.height.toInt(),
      scale: state.noise.scale,
      octaves: state.noise.octaves,
      persistence: state.noise.persistence,
      seed: state.noise.seed,
    );
    state = state.copyWith(cachedData: heightmap);
  }

  void updateName(String name) {
    state = state.copyWith(name: name);
  }

  void updateBlendMode(LayerBlendMode blendMode) {
    state = state.copyWith(blendMode: blendMode);
  }

  void updateNoiseParams(LayerNoiseParams noiseParams) {
    state = state.copyWith(noise: noiseParams);
    generateHeightmap();
  }
}
