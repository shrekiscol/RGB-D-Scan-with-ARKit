//
//  Renderer.swift
//  ColoredPointCloud
//
//  Created by hvrl_mt on 2022/04/25.
//

import MetalKit
import ARKit

// Vertex data for an image plane
// This is composed of quadruplets (x, y, u, v)
let kImagePlaneVertexData: [Float] = [
    -1.0, -1.0,  1.0, 1.0,    // x1, y1, u1, v1
     1.0, -1.0,  1.0, 0.0,    // x2, y2, u2, v2
    -1.0,  1.0,  0.0, 1.0,    // x3, y3, u3, v3
     1.0,  1.0,  0.0, 0.0,    // x4, y4, u4, v4
]

// MARK: - Triple buffering for Camera Uniforms
// The max number of command buffers in flight
let kMaxBuffersInFlight: Int = 3

// The 256 byte aligned size of our uniform structures
let kAlignedSharedUniformsSize: Int = (MemoryLayout<Uniforms>.size & ~0xFF) + 0x100

// Used to determine _uniformBufferStride each frame. This is the current frame number modulo kMaxBuffersInFlight
var uniformBufferIndex: Int = 0

// Offset within _sharedUniformBuffer to set for the current frame
var sharedUniformBufferOffset: Int = 0


class Renderer: NSObject {
    static var device: MTLDevice!
    static var commandQueue: MTLCommandQueue!
    static var library: MTLLibrary!
    
    static var imagePlaneVertexBuffer: MTLBuffer!
    
    static var session: ARSession!
    
    // The current viewport size
    static var viewportSize: CGSize = CGSize()
    
    // Flag for viewport size changes
    static var viewportSizeDidChange: Bool = false
    
    // Camera Uniforms
    static var sharedUniformBuffer: MTLBuffer!
    /// Offset within _sharedUniformBuffer to set for the current frame
    static var sharedUniformBufferOffset: Int = 0
    /// Addresses to write shared uniforms to each frame
    static var sharedUniformBufferAddress: UnsafeMutableRawPointer!
    
    var renderMode: RenderMode = .cameraImage
    
    let inFlightSemaphore = DispatchSemaphore(value: kMaxBuffersInFlight)
    
    var camera: Camera!
    
    var capturedImage: CapturedImage
    var depthImage: DepthImage
    
    var pointCloud: PointCloud
    var particle: Particle
    
    var depthImageView: UIImageView
    
    var parameters: Parameters
    var directoryID: Int
    
    var delegate: StatusLogDelegate?
    // Save every `saveSpan` frames
    let saveSpan: Int = 2
    var frameCount = 0
    
    init(metalView: MTKView, session: ARSession, depthImageView: UIImageView, directoryID: Int) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            fatalError("GPU not available")
        }
        
        self.depthImageView = depthImageView
        self.directoryID = directoryID
        
        Renderer.device = device
        Renderer.commandQueue = commandQueue
        Renderer.library = device.makeDefaultLibrary()
        Renderer.session = session
        
        Renderer.initializeImagePlane()
        
        camera = Camera()

        capturedImage = CapturedImage()
        depthImage = DepthImage()
        
        pointCloud = PointCloud()
        particle = Particle()
        
        parameters = Parameters()
        
        // Set up metal view
        metalView.device = device
        metalView.depthStencilPixelFormat = .depth32Float
        metalView.colorPixelFormat = .bgra8Unorm
        
        // Calculate our uniform buffer sizes. We allocate kMaxBuffersInFlight instances for uniform
        //   storage in a single buffer. This allows us to update uniforms in a ring (i.e. triple
        //   buffer the uniforms) so that the GPU reads from one slot in the ring wil the CPU writes
        //   to another. Anchor uniforms should be specified with a max instance count for instancing.
        //   Also uniform storage must be aligned (to 256 bytes) to meet the requirements to be an
        //   argument in the constant address space of our shading functions.
        let sharedUniformBufferSize = kAlignedSharedUniformsSize * kMaxBuffersInFlight
        
        // Create and allocate our uniform buffer objects. Indicate shared storage so that both the CPU can access the buffer
        Renderer.sharedUniformBuffer = device.makeBuffer(length: sharedUniformBufferSize,
                                                         options: .storageModeShared)
        Renderer.sharedUniformBuffer.label = "SharedUniformBuffer"
                
        super.init()
        metalView.delegate = self
    }
    
    /// Create a vertex buffer with our image plane vertex data.
    /// Everything is rendered on this plane
    static func initializeImagePlane() {
        let imagePlaneVertexDataCount = kImagePlaneVertexData.count * MemoryLayout<Float>.size
        
        Renderer.imagePlaneVertexBuffer = Renderer.device.makeBuffer(bytes: kImagePlaneVertexData,
                                                                     length: imagePlaneVertexDataCount,
                                                                     options: [])
        Renderer.imagePlaneVertexBuffer.label = "ImagePlaneVertexBuffer"
    }
    
        
    static func drawRectResized(size: CGSize) {
        Renderer.viewportSize = size
        Renderer.viewportSizeDidChange = true
    }
    
    // MARK: - Update
    
    /// Update the texture coordinates of our image plane to aspect fill the viewport
    /// - Parameter frame: Currently captured frame
    func updateImagePlane(frame: ARFrame) {
        let displayToCameraTransform = frame.displayTransform(for: .portrait,
                                                              viewportSize: Renderer.viewportSize).inverted()
        let vertexData = Renderer.imagePlaneVertexBuffer.contents().assumingMemoryBound(to: Float.self)
        for index in 0...3 {
            let textureCoordIndex = 4 * index + 2
            let textureCoord = CGPoint(x: CGFloat(kImagePlaneVertexData[textureCoordIndex + 1]),
                                       y: CGFloat(kImagePlaneVertexData[textureCoordIndex]))
            let transformedCoord = textureCoord.applying(displayToCameraTransform)
            vertexData[textureCoordIndex] = Float(transformedCoord.x)
            vertexData[textureCoordIndex + 1] = 1 - Float(transformedCoord.y)
        }
    }
    
    
    
    /// Update the location(s) to which we'll write to in our dynamically changing Metal buffers for the current frame
    /// (i.e. update our slot in the ring buffer used for the current frame)
    func updateBufferStates() {
        uniformBufferIndex = (uniformBufferIndex + 1) % kMaxBuffersInFlight
        
        Renderer.sharedUniformBufferOffset = kAlignedSharedUniformsSize * uniformBufferIndex
        Renderer.sharedUniformBufferAddress = Renderer.sharedUniformBuffer.contents().advanced(by: Renderer.sharedUniformBufferOffset)
        
        pointCloud.uniformBufferOffset = kAlignedPointCloudUniformsSize * uniformBufferIndex
        pointCloud.uniformBufferAddress = pointCloud.uniformBuffer.contents().advanced(by: pointCloud.uniformBufferOffset)
    }
    
    
    func updateGameState(frame: ARFrame) {
        updateSharedUniforms(frame: frame)
        capturedImage.updateCapturedImageTextures(frame: frame)
        depthImage.updateDepthTextures(frame: frame, parameters: parameters)
        pointCloud.update(camera: frame.camera, currentPointIndex: particle.currentPointIndex)
        
        // Update parameters for JSON file
        let camera = frame.camera
        parameters.intrinsic = camera.intrinsics
        parameters.viewMatrix = camera.viewMatrix(for: .portrait)
        
        frameCount += 1
        if ViewController.isRecording && frameCount % saveSpan == 0  {
            saveFiles(frame: frame)
        }
        
        if renderMode == .depthMap {
            // Update depth map image view
            let image = depthImage.convertToDepthMapUIImage(frame: frame)
            DispatchQueue.main.async {
                self.depthImageView.image = image
            }
            depthImageView.image = image
        } else if renderMode == .confidenceMap {
            // Update confidence map image view
            let image = depthImage.convertToConfidenceMapUIImage(frame: frame)
            DispatchQueue.main.async {
                self.depthImageView.image = image
            }
        } else {
            depthImageView.image = nil
        }
        
        if Renderer.viewportSizeDidChange {
            Renderer.viewportSizeDidChange = false
            updateImagePlane(frame: frame)
        }
    }
    
    func saveFiles(frame: ARFrame) {
        // Save files
        guard let capturedUIImage = frame.capturedImage.convertToUIImage(ciContext: capturedImage.ciContext),
              let root = ViewController.rootDirectory,
              let sceneDepth = frame.sceneDepth,
              let confidenceMap = sceneDepth.confidenceMap,
              let confidenceMapUIImage = confidenceMap.convertToUIImage(ciContext: depthImage.ciContext),
              let delegate = delegate
        else { return }
        
        
        let directory = root.appendingPathComponent("RGB", isDirectory: true)
        let confidenceDirectory = root.appendingPathComponent("Confidence", isDirectory: true)
        let parameterDirectory = root.appendingPathComponent("Frame", isDirectory: true)
        
        let format = "jpg"           // used for RGB
        let confidenceFormat = "png" // confidence is categorical -- must stay lossless
        
        let jsonEncoder = JSONEncoder()
        jsonEncoder.outputFormatting = .prettyPrinted
    
        delegate.incrementTotalFrames()
        Task.init(priority: .utility) {
            do {
                let count = delegate.savedFrames
                let rgbURL = directory.appendingPathComponent("rgb_\(count)").appendingPathExtension(format)
                let confidenceURL = confidenceDirectory.appendingPathComponent("confidence_\(count)").appendingPathExtension(confidenceFormat)
                let parameterURL = parameterDirectory.appendingPathComponent("frame_\(count)").appendingPathExtension("json")
                
                try await saveImageAsync(uiImage: capturedUIImage, url: rgbURL, format: format)
                try await saveImageAsync(uiImage: confidenceMapUIImage, url: confidenceURL, format: confidenceFormat)
                try await parameters.save(jsonEncoder: jsonEncoder, url: parameterURL)
                
                delegate.incrementSavedFrames()
            } catch let error {
                fatalError(error.localizedDescription)
            }
        }
    }
    
    
    /// Update the shared uniforms of the frame
    /// - Parameter frame: Currently captured frame
    func updateSharedUniforms(frame: ARFrame) {
        let uniforms = Renderer.sharedUniformBufferAddress.assumingMemoryBound(to: Uniforms.self)
        
        uniforms.pointee.viewMatrix = frame.camera.viewMatrix(for: .portrait)
        uniforms.pointee.projectionMatrix = frame.camera.projectionMatrix(for: .portrait,
                                                                          viewportSize: Renderer.viewportSize,
                                                                          zNear: 0.001,
                                                                          zFar: 1000)
    }
}

// MARK: - MTKViewDelegate

extension Renderer: MTKViewDelegate {
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        Renderer.drawRectResized(size: size)
    }
    
    func draw(in view: MTKView) {
        guard let currentFrame = Renderer.session.currentFrame,
              let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let commandBuffer = Renderer.commandQueue.makeCommandBuffer(),
              let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)
        else { return }
        
//        print(currentFrame.camera.imageResolution)
        
        // Wait to ensure only kMaxBuffersInFlight are getting processed by any stage in the Metal pipeline (App, Metal, Drivers, GPU, etc)
        let _ = inFlightSemaphore.wait(timeout: DispatchTime.distantFuture)
        
        // Add completion handler which signal _inFlightSemaphore when Metal and the GPU has fully
        //   finished processing the commands we're encoding this frame.  This indicates when the
        //   dynamic buffers, that we're writing to this frame, will no longer be needed by Metal
        //   and the GPU.
        // Retain our CVMetalTextures for the duration of the rendering cycle. The MTLTextures
        //   we use from the CVMetalTextures are not valid unless their parent CVMetalTextures
        //   are retained. Since we may release our CVMetalTexture ivars during the rendering
        //   cycle, we must retain them separately here.
        var textures = [capturedImage.textureY, capturedImage.textureCbCr, depthImage.depthTexture, depthImage.confidenceTexture]
        commandBuffer.addCompletedHandler{ [weak self] commandBuffer in
            if let strongSelf = self {
                strongSelf.inFlightSemaphore.signal()
            }
            textures.removeAll()
        }
        
        updateBufferStates()
        updateGameState(frame: currentFrame)
        
        switch renderMode {
        case .cameraImage:
            
            if shouldAccumulate(frame: currentFrame) {
                computePointCloud(renderEncoder: renderEncoder, commandBuffer: commandBuffer, currentFrame: currentFrame)
            }

            if ViewController.showPointCloud {
                particle.draw(renderEncoder: renderEncoder, pointCloud: pointCloud)
            } else {
                capturedImage.draw(renderEncoder: renderEncoder)
            }
            
        case .depthMap, .confidenceMap:
            break
        }
        
        renderEncoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
    
    func shouldAccumulate(frame: ARFrame) -> Bool {
        let cameraTransform = frame.camera.transform
        
        return particle.currentPointCount == 0
            || dot(cameraTransform.columns.2, camera.lastTransform.columns.2) <= camera.rotationThreshold
            || distance_squared(cameraTransform.columns.3, camera.lastTransform.columns.3) >= camera.translationThreshold
    }
    
    func computePointCloud(renderEncoder: MTLRenderCommandEncoder,
                           commandBuffer: MTLCommandBuffer,
                           currentFrame: ARFrame) {
        
        guard let textureY = capturedImage.textureY,
              let textureCbCr = capturedImage.textureCbCr,
              let textureDepth = depthImage.depthTexture,
              let textureConfidence = depthImage.confidenceTexture else {
            return
        }
        
                
        var retainingTextures = [textureY, textureCbCr, textureDepth, textureConfidence]
        commandBuffer.addCompletedHandler { buffer in
            retainingTextures.removeAll()
        }
        
        pointCloud.updateGridPoints(camera: currentFrame.camera)
        
        // Push a debug group allowing us to identify render commands in the GPU Frame Capture tool
        renderEncoder.pushDebugGroup("ComputePointCloud")
        
        renderEncoder.setDepthStencilState(pointCloud.depthStencilState)
        renderEncoder.setRenderPipelineState(pointCloud.unprojectionPipelineState)
        
        // Grid points
        renderEncoder.setVertexBuffer(pointCloud.gridPointsBuffer,
                                      offset: 0,
                                      index: Int(kBufferIndexGridPoints.rawValue))
        // Point cloud
        renderEncoder.setVertexBuffer(pointCloud.uniformBuffer,
                                      offset: pointCloud.uniformBufferOffset,
                                      index: Int(kBufferIndexPointCloudUniforms.rawValue))
        // Particle buffers (values are computed and stored in the shader)
        renderEncoder.setVertexBuffer(particle.uniformBuffer,
                                      offset: 0,
                                      index: Int(kBufferIndexParticleUniforms.rawValue))
        
        // Set textures
        renderEncoder.setVertexTexture(CVMetalTextureGetTexture(textureY), index: Int(kTextureIndexY.rawValue))
        renderEncoder.setVertexTexture(CVMetalTextureGetTexture(textureCbCr), index: Int(kTextureIndexCbCr.rawValue))
        renderEncoder.setVertexTexture(CVMetalTextureGetTexture(textureDepth), index: Int(kTextureIndexDepth.rawValue))
        renderEncoder.setVertexTexture(CVMetalTextureGetTexture(textureConfidence), index: Int(kTextureIndexConfidence.rawValue))
        
        // Draw (compute but render nothing)
        renderEncoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: pointCloud.gridPoints.count)
        
//        print(pointCloud.gridPoints.count)
        
        particle.currentPointIndex = (particle.currentPointIndex + pointCloud.gridPoints.count) % nMaxPointCount
        particle.currentPointCount = min(particle.currentPointCount + pointCloud.gridPoints.count, nMaxPointCount)
        camera.lastTransform = currentFrame.camera.transform
        
//        print(particle.currentPointIndex, particle.currentPointCount)
        renderEncoder.popDebugGroup()

    }
    
}


enum RenderMode {
    case cameraImage
    case depthMap
    case confidenceMap
}
