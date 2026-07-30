//
//  Helper.swift
//  ColoredPointCloud
//
//  Created by hvrl_mt on 2022/05/04.
//

import UIKit

extension UIImage {

    func rotatedBy(degree: CGFloat, isCropped: Bool = true) -> UIImage {
        let radian = -degree * CGFloat.pi / 180
        var rotatedRect = CGRect(origin: .zero, size: self.size)
        if !isCropped {
            rotatedRect = rotatedRect.applying(CGAffineTransform(rotationAngle: radian))
        }
        UIGraphicsBeginImageContext(rotatedRect.size)
        let context = UIGraphicsGetCurrentContext()!
        context.translateBy(x: rotatedRect.size.width / 2, y: rotatedRect.size.height / 2)
        context.scaleBy(x: 1.0, y: -1.0)
        
        context.rotate(by: radian)
        context.draw(self.cgImage!, in: CGRect(x: -(self.size.width / 2), y: -(self.size.height / 2), width: self.size.width, height: self.size.height))
        
        let rotatedImage = UIGraphicsGetImageFromCurrentImageContext()!
        UIGraphicsEndImageContext()
        return rotatedImage
    }

}

extension CVPixelBuffer {
    func convertToUIImage(ciContext: CIContext) -> UIImage? {
        let ciImage = CIImage(cvPixelBuffer: self)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return nil }
        return UIImage(cgImage: cgImage)   // no rotation -- keep native orientation, matching raw depth + camera.intrinsics
    }
}

extension simd_float3x3: @retroactive Codable {
    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        try self.init(container.decode([Float3].self))
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode([columns.0, columns.1, columns.2])
    }
}

extension simd_float4x4: @retroactive Codable {
    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        try self.init(container.decode([Float4].self))
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode([columns.0, columns.1, columns.2, columns.3])
    }
}


/// Creates a directory in Documents Directory to save data
/// - Parameter directoryName: The name of the directory to create.
func createSaveDirectory(directoryName: String) {
    
    // MARK: - If directory `directoryID` does not exist, create a new one
    let fileManager = ViewController.fileManager
    guard let root = ViewController.rootDirectory else { fatalError() }
    
    if !fileManager.fileExists(atPath: root.path) {
        do {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true, attributes: nil)
        } catch {
            fatalError("Failed to create a directory!")
        }
    }
    
    // MARK: - Create a new directory with the specified name under `root`
    let directory = root.appendingPathComponent(directoryName, isDirectory: true)
    
    do {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
    } catch {
        fatalError("Failed to create a directory!")
    }
}

/// Returns an ID used to create a directory in which RGB/Depth/Confidence are saved.
/// - Returns: a directory ID
func determineDirectoryID() -> Int {
    let fileManager = ViewController.fileManager
    let documentsDirectory = fileManager.urls(for: .documentDirectory,
                                              in: .userDomainMask).first!
    
    var id: Int = 0
    do {
        let fileList = try fileManager.contentsOfDirectory(at: documentsDirectory, includingPropertiesForKeys: nil)
        id = fileList.count
    } catch let error {
        print(error)
    }
    
    return id
}

func getRootDirectory(directoryID: Int) -> URL {
    let documentsDirectory = ViewController.fileManager.urls(for: .documentDirectory,
                                                             in: .userDomainMask).first!
    let root = documentsDirectory.appendingPathComponent(String(directoryID), isDirectory: true)
    
    return root
}

func saveImageAsync(uiImage: UIImage, url: URL, format: String = "png") async throws -> () {
    do {
        if format == "png",
           let image = uiImage.pngData() {
            try image.write(to: url)
        } else if format == "jpg",
                  let image = uiImage.jpegData(compressionQuality: 0.9) {
            try image.write(to: url)
        }
    } catch let error {
        print("Failed to save an image: \(url) due to \(error.localizedDescription)")
    }
}
