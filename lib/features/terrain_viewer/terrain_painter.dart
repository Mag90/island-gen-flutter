import 'dart:typed_data';
import 'package:flutter/material.dart' hide Matrix4;
import 'package:flutter_gpu/gpu.dart' as gpu;
import 'package:island_gen_flutter/features/editor/providers/terrain_settings_provider/terrain_settings_provider.dart';
import 'package:island_gen_flutter/features/terrain_viewer/orbit_camera.dart';
import 'package:island_gen_flutter/shaders.dart';
import 'package:vector_math/vector_math.dart';
import 'package:island_gen_flutter/features/terrain_viewer/terrain_mesh.dart';

class TerrainPainter extends CustomPainter {
  final TerrainMesh terrainMesh;
  final OrbitCamera camera;
  final RenderMode renderMode;

  const TerrainPainter({
    required this.terrainMesh,
    required this.camera,
    required this.renderMode,
  });

  // Create vertex and index buffers
  (gpu.DeviceBuffer, gpu.DeviceBuffer, gpu.DeviceBuffer) _createBuffers() {
    final verticesBuffer = gpu.gpuContext.createDeviceBufferWithCopy(
      ByteData.sublistView(terrainMesh.vertices),
    )!;

    final indexBuffer = gpu.gpuContext.createDeviceBufferWithCopy(
      ByteData.sublistView(terrainMesh.indices),
    )!;

    final lineIndexBuffer = gpu.gpuContext.createDeviceBufferWithCopy(
      ByteData.sublistView(terrainMesh.lineIndices),
    )!;

    return (verticesBuffer, indexBuffer, lineIndexBuffer);
  }

  // Create transformation matrices and camera data
  ({
    Matrix4 mvp,
    Matrix4 modelView,
    Vector3 cameraPosition,
    double aspect,
  }) _createTransforms(Size size) {
    final aspect = size.width / size.height;
    final projection = camera.getProjectionMatrix(aspect);
    final view = camera.getViewMatrix();
    final model = Matrix4.identity();
    final mvp = projection * view * model;
    final modelView = view * model;

    final viewInverse = view.clone()..invert();
    final cameraPosition = viewInverse.getTranslation();

    return (
      mvp: mvp,
      modelView: modelView,
      cameraPosition: cameraPosition,
      aspect: aspect,
    );
  }

  // Create and fill uniform buffer
  gpu.DeviceBuffer _createUniformBuffer({
    required Matrix4 mvp,
    required Matrix4 modelView,
    required Vector3 cameraPosition,
    required Vector3 lightColor,
    required double ambientStrength,
    required double specularStrength,
  }) {
    final uniformData = Float32List(16 + 16 + 4 + 4 + 4);
    int offset = 0;

    // Pass MVP matrix
    uniformData.setAll(offset, mvp.storage);
    offset += 16;

    // Pass model-view matrix
    uniformData.setAll(offset, modelView.storage);
    offset += 16;

    // Pass light position
    final lightPositionWorld = cameraPosition + Vector3(5.0, 5.0, 0.0);
    uniformData[offset++] = lightPositionWorld.x;
    uniformData[offset++] = lightPositionWorld.y;
    uniformData[offset++] = lightPositionWorld.z;
    uniformData[offset++] = 1.0;

    // Pass light color
    uniformData[offset++] = lightColor.x;
    uniformData[offset++] = lightColor.y;
    uniformData[offset++] = lightColor.z;
    uniformData[offset++] = 0.0;

    // Pass parameters
    uniformData[offset++] = ambientStrength;
    uniformData[offset++] = specularStrength;
    uniformData[offset++] = terrainMesh.gridSize.toDouble();
    uniformData[offset++] = 0.0;

    return gpu.gpuContext.createDeviceBufferWithCopy(
      ByteData.sublistView(uniformData),
    )!;
  }

  // Set up render pass with common settings
  (gpu.CommandBuffer, gpu.RenderPass) _setupRenderPass(gpu.RenderTarget renderTarget) {
    final commandBuffer = gpu.gpuContext.createCommandBuffer();
    final renderPass = commandBuffer.createRenderPass(renderTarget);
    renderPass.setDepthWriteEnable(true);
    renderPass.setDepthCompareOperation(gpu.CompareFunction.less);
    return (commandBuffer, renderPass);
  }

  @override
  void paint(Canvas canvas, Size size) {
    // Create a texture to render our 3D scene into
    final texture = gpu.gpuContext.createTexture(
      gpu.StorageMode.devicePrivate,
      size.width.toInt(),
      size.height.toInt(),
    )!;

    // Create a depth texture for depth testing
    final depthTexture = gpu.gpuContext.createTexture(
      gpu.StorageMode.devicePrivate,
      size.width.toInt(),
      size.height.toInt(),
      format: gpu.gpuContext.defaultDepthStencilFormat,
    );

    if (depthTexture == null) {
      throw Exception('Failed to create depth texture');
    }

    // Set up the render target
    final renderTarget = gpu.RenderTarget.singleColor(
      gpu.ColorAttachment(
        texture: texture,
        clearValue: Vector4(0.1, 0.1, 0.1, 1.0),
      ),
      depthStencilAttachment: gpu.DepthStencilAttachment(
        texture: depthTexture,
        depthLoadAction: gpu.LoadAction.clear,
        depthStoreAction: gpu.StoreAction.store,
        depthClearValue: 1.0,
        stencilLoadAction: gpu.LoadAction.clear,
        stencilStoreAction: gpu.StoreAction.dontCare,
        stencilClearValue: 0,
      ),
    );

    // Create common resources
    final (verticesBuffer, indexBuffer, lineIndexBuffer) = _createBuffers();
    final transforms = _createTransforms(size);
    final uniformBuffer = _createUniformBuffer(
      mvp: transforms.mvp,
      modelView: transforms.modelView,
      cameraPosition: transforms.cameraPosition,
      lightColor: Vector3(1.0, 1.0, 1.0),
      ambientStrength: 0.3,
      specularStrength: 0.7,
    );

    switch (renderMode) {
      case RenderMode.wireframe:
        {
          // Get shaders and create pipeline
          final vert = shaderLibrary['TerrainVertex']!;
          final frag = shaderLibrary['WireframeFragment']!;
          final pipeline = gpu.gpuContext.createRenderPipeline(vert, frag);

          // Set up render pass
          final (commandBuffer, renderPass) = _setupRenderPass(renderTarget);

          // Bind pipeline and buffers
          renderPass.bindPipeline(pipeline);
          renderPass.bindVertexBuffer(
            gpu.BufferView(
              verticesBuffer,
              offsetInBytes: 0,
              lengthInBytes: verticesBuffer.sizeInBytes,
            ),
            terrainMesh.vertices.length ~/ 8,
          );

          // Bind uniforms (only to vertex shader for wireframe)
          renderPass.bindUniform(
            vert.getUniformSlot('Transforms'),
            gpu.BufferView(
              uniformBuffer,
              offsetInBytes: 0,
              lengthInBytes: uniformBuffer.sizeInBytes,
            ),
          );

          // Draw wireframe
          renderPass.bindIndexBuffer(
            gpu.BufferView(
              lineIndexBuffer,
              offsetInBytes: 0,
              lengthInBytes: lineIndexBuffer.sizeInBytes,
            ),
            gpu.IndexType.int16,
            terrainMesh.lineIndices.length,
          );
          renderPass.setPrimitiveType(gpu.PrimitiveType.line);
          renderPass.draw();

          commandBuffer.submit();
        }
        break;

      case RenderMode.solid:
        {
          // Get shaders and create pipeline
          final vert = shaderLibrary['TerrainVertex']!;
          final frag = shaderLibrary['TerrainFragment']!;
          final pipeline = gpu.gpuContext.createRenderPipeline(vert, frag);

          // Set up render pass
          final (commandBuffer, renderPass) = _setupRenderPass(renderTarget);

          // Bind pipeline and buffers
          renderPass.bindPipeline(pipeline);
          renderPass.bindVertexBuffer(
            gpu.BufferView(
              verticesBuffer,
              offsetInBytes: 0,
              lengthInBytes: verticesBuffer.sizeInBytes,
            ),
            terrainMesh.vertices.length ~/ 8,
          );

          // Bind uniforms
          renderPass.bindUniform(
            vert.getUniformSlot('Transforms'),
            gpu.BufferView(
              uniformBuffer,
              offsetInBytes: 0,
              lengthInBytes: uniformBuffer.sizeInBytes,
            ),
          );

          renderPass.bindUniform(
            frag.getUniformSlot('Transforms'),
            gpu.BufferView(
              uniformBuffer,
              offsetInBytes: 0,
              lengthInBytes: uniformBuffer.sizeInBytes,
            ),
          );

          // Draw triangles
          renderPass.bindIndexBuffer(
            gpu.BufferView(
              indexBuffer,
              offsetInBytes: 0,
              lengthInBytes: indexBuffer.sizeInBytes,
            ),
            gpu.IndexType.int16,
            terrainMesh.indices.length,
          );
          renderPass.setPrimitiveType(gpu.PrimitiveType.triangle);
          renderPass.draw();

          commandBuffer.submit();
        }
        break;

      case RenderMode.color:
        {
          // Get shaders and create pipeline
          final vert = shaderLibrary['TerrainVertex']!;
          final frag = shaderLibrary['ColorFragment']!;
          final pipeline = gpu.gpuContext.createRenderPipeline(vert, frag);

          // Set up render pass
          final (commandBuffer, renderPass) = _setupRenderPass(renderTarget);

          // Bind pipeline and buffers
          renderPass.bindPipeline(pipeline);
          renderPass.bindVertexBuffer(
            gpu.BufferView(
              verticesBuffer,
              offsetInBytes: 0,
              lengthInBytes: verticesBuffer.sizeInBytes,
            ),
            terrainMesh.vertices.length ~/ 8,
          );

          // Bind uniforms
          renderPass.bindUniform(
            vert.getUniformSlot('Transforms'),
            gpu.BufferView(
              uniformBuffer,
              offsetInBytes: 0,
              lengthInBytes: uniformBuffer.sizeInBytes,
            ),
          );

          renderPass.bindUniform(
            frag.getUniformSlot('Transforms'),
            gpu.BufferView(
              uniformBuffer,
              offsetInBytes: 0,
              lengthInBytes: uniformBuffer.sizeInBytes,
            ),
          );

          // Draw triangles
          renderPass.bindIndexBuffer(
            gpu.BufferView(
              indexBuffer,
              offsetInBytes: 0,
              lengthInBytes: indexBuffer.sizeInBytes,
            ),
            gpu.IndexType.int16,
            terrainMesh.indices.length,
          );
          renderPass.setPrimitiveType(gpu.PrimitiveType.triangle);
          renderPass.draw();

          commandBuffer.submit();
        }
        break;
    }

    // Draw the result to the canvas
    final image = texture.asImage();
    canvas.drawImage(image, Offset.zero, Paint());
  }

  @override
  bool shouldRepaint(covariant TerrainPainter oldDelegate) {
    return true; // Always repaint when camera changes
  }
}
