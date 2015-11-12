//
//  UploadDescriptor.swift
//  VimeoUpload
//
//  Created by Alfred Hanssen on 10/18/15.
//  Copyright © 2015 Vimeo. All rights reserved.
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.
//

import Foundation

class UploadDescriptor: Descriptor
{
    // MARK:
    
    let url: NSURL
    var videoSettings: VideoSettings?
    
    // MARK:
    
    private(set) var createVideoResponse: CreateVideoResponse? // Create response
    private(set) var videoUri: String? // Activate response
    private(set) var video: VIMVideo? // Settings response
    
    // MARK:
    
    private static let ProgressKeyPath = "fractionCompleted"
    private var progressKVOContext = UInt8()
    private var isObserving = false
    private var uploadProgressObject: NSProgress?
    private(set) dynamic var uploadProgress: Double = 0 // KVO on this property

    // MARK:
    
    private(set) var currentRequest = UploadRequest.Create
    {
        didSet
        {
            print(self.currentRequest.rawValue)
        }
    }

    override var error: NSError?
    {
        didSet
        {
            if self.error != nil
            {
                print(self.error!.localizedDescription)
                self.currentTaskIdentifier = nil
                self.state = .Finished
            }
        }
    }
    
    // MARK:
    
    // MARK: Initialization

    deinit
    {
        self.removeObserverIfNecessary()
    }
    
    convenience init(url: NSURL)
    {
        self.init(url: url, videoSettings: nil)
    }

    init(url: NSURL, videoSettings: VideoSettings?)
    {
        self.url = url
        self.videoSettings = videoSettings
    
        super.init()
    }

    // MARK: Overrides
    
    override func start(sessionManager: AFURLSessionManager) throws
    {
        try super.start(sessionManager)
        
        self.state = .Executing

        do
        {
            let sessionManager = sessionManager as! VimeoSessionManager
            try self.transitionToState(.Create, sessionManager: sessionManager)
        }
        catch let error as NSError
        {
            self.error = error

            throw error // Propagate this out so that DescriptorManager can remove the descriptor from the set
        }
    }

    // If necessary, resume the current task and re-connect progress objects

    override func didLoadFromCache(sessionManager: AFURLSessionManager)
    {
        // TODO: restart tasks
        
        let results = sessionManager.uploadTasks.filter( { ($0 as! NSURLSessionUploadTask).taskIdentifier == self.currentTaskIdentifier } )
        
        assert(results.count < 2, "Upon reconnecting upload tasks with descriptors, found 2 tasks with same identifier")
        
        if results.count == 1
        {
            let task  = results.first as! NSURLSessionUploadTask
            self.uploadProgressObject = sessionManager.uploadProgressForTask(task)
            self.addObserver()
        }
    }

    override func taskDidFinishDownloading(sessionManager: AFURLSessionManager, task: NSURLSessionDownloadTask, url: NSURL) -> NSURL?
    {
        let sessionManager = sessionManager as! VimeoSessionManager
        let responseSerializer = sessionManager.responseSerializer as! VimeoResponseSerializer
        
        // TODO: check for Vimeo error here?
        
        do
        {
            switch self.currentRequest
            {
            case .Create:
                self.createVideoResponse = try responseSerializer.processCreateVideoResponse(task.response, url: url, error: error)
                
            case .Upload:
                break
                
            case .Activate:
                self.videoUri = try responseSerializer.processActivateVideoResponse(task.response, url: url, error: error)
                
            case .Settings:
                self.video = try responseSerializer.processVideoSettingsResponse(task.response, url: url, error: error)
            }
        }
        catch let error as NSError
        {
            self.error = error
        }

        return nil
    }
    
    override func taskDidComplete(sessionManager: AFURLSessionManager, task: NSURLSessionTask, error: NSError?)
    {
        if self.currentRequest == .Upload
        {
            self.cleanupAfterUpload()
        }

        if self.error == nil
        {
            if let taskError = task.error // task.error is reserved for client-side errors, so check it first
            {
                self.error = taskError // TODO: add proper vimeo domain
            }
            else if let error = error
            {
                self.error = error // TODO: add proper vimeo domain
            }
        }
        
        let nextRequest = UploadRequest.nextRequest(self.currentRequest)
        if self.error != nil || nextRequest == nil || (nextRequest == .Settings && self.videoSettings == nil)
        {
            self.currentTaskIdentifier = nil
            self.state = .Finished

            return
        }
        
        do
        {
            let sessionManager = sessionManager as! VimeoSessionManager
            try self.transitionToState(nextRequest!, sessionManager: sessionManager)
            if self.currentRequest == .Upload
            {
                self.addObserver()
            }
        }
        catch let error as NSError
        {
            self.error = error
        }
    }
    
    // MARK: Private API
    
    private func transitionToState(request: UploadRequest, sessionManager: VimeoSessionManager) throws
    {
        self.currentRequest = request
        let task = try self.taskForRequest(request, sessionManager: sessionManager)
        self.currentTaskIdentifier = task.taskIdentifier
        task.resume()
    }
    
    private func taskForRequest(request: UploadRequest, sessionManager: VimeoSessionManager) throws -> NSURLSessionTask
    {
        switch request
        {
        case .Create:
            return try sessionManager.createVideoDownloadTask(url: self.url)
            
        case .Upload:
            guard let uploadUri = self.createVideoResponse?.uploadUri else
            {
                throw NSError(domain: UploadErrorDomain.Upload.rawValue, code: 0, userInfo: [NSLocalizedDescriptionKey: "Attempt to initiate upload but the uploadUri is nil."])
            }

            return try sessionManager.uploadVideoTask(self.url, destination: uploadUri, progress: &self.uploadProgressObject, completionHandler: nil)
            
        case .Activate:
            guard let activationUri = self.createVideoResponse?.activationUri else
            {
                throw NSError(domain: UploadErrorDomain.Activate.rawValue, code: 0, userInfo: [NSLocalizedDescriptionKey: "Activate response did not contain the required values."])
            }
            
            return try sessionManager.activateVideoDownloadTask(uri: activationUri)

        case .Settings:
            guard let videoUri = self.videoUri, let videoSettings = self.videoSettings else
            {
                throw NSError(domain: UploadErrorDomain.VideoSettings.rawValue, code: 0, userInfo: [NSLocalizedDescriptionKey: "Video settings response did not contain the required values."])
            }
            
            return try sessionManager.videoSettingsDownloadTask(videoUri: videoUri, videoSettings: videoSettings)
        }
    }

    private func cleanupAfterUpload()
    {
        self.removeObserverIfNecessary()
        
        if let path = self.url.path where NSFileManager.defaultManager().fileExistsAtPath(path)
        {
            _ = try? NSFileManager.defaultManager().removeItemAtPath(path)
        }
    }
    
    // MARK: KVO
    
    private func addObserver()
    {
        self.uploadProgressObject?.addObserver(self, forKeyPath: UploadDescriptor.ProgressKeyPath, options: NSKeyValueObservingOptions.New, context: &self.progressKVOContext)
        self.isObserving = true
    }
    
    private func removeObserverIfNecessary()
    {
        if self.isObserving
        {
            self.uploadProgressObject?.removeObserver(self, forKeyPath: UploadDescriptor.ProgressKeyPath, context: &self.progressKVOContext)
            self.isObserving = false
        }
    }
    
    override func observeValueForKeyPath(keyPath: String?, ofObject object: AnyObject?, change: [String : AnyObject]?, context: UnsafeMutablePointer<Void>)
    {
        if let keyPath = keyPath
        {
            switch (keyPath, context)
            {
            case(UploadDescriptor.ProgressKeyPath, &self.progressKVOContext):
                let progress = change?[NSKeyValueChangeNewKey]?.doubleValue ?? 0;
                self.uploadProgress = progress
                print("Inner Upload: \(progress)")
                
            default:
                super.observeValueForKeyPath(keyPath, ofObject: object, change: change, context: context)
            }
        }
        else
        {
            super.observeValueForKeyPath(keyPath, ofObject: object, change: change, context: context)
        }
    }
    
    // MARK: NSCoding
    
    required init(coder aDecoder: NSCoder)
    {
        self.url = aDecoder.decodeObjectForKey("url") as! NSURL // If force unwrap fails we have a big problem
        self.videoSettings = aDecoder.decodeObjectForKey("videoSettings") as? VideoSettings
        self.createVideoResponse = aDecoder.decodeObjectForKey("createVideoResponse") as? CreateVideoResponse
        self.videoUri = aDecoder.decodeObjectForKey("videoUri") as? String
        self.currentRequest = UploadRequest(rawValue: aDecoder.decodeObjectForKey("currentRequest") as! String)!

        super.init(coder: aDecoder)
    }
    
    override func encodeWithCoder(aCoder: NSCoder)
    {
        aCoder.encodeObject(self.url, forKey: "url")
        aCoder.encodeObject(self.videoSettings, forKey: "videoSettings")
        aCoder.encodeObject(self.createVideoResponse, forKey: "createVideoResponse")
        aCoder.encodeObject(self.videoUri, forKey: "videoUri")
        aCoder.encodeObject(self.currentRequest.rawValue, forKey: "currentRequest")
        
        super.encodeWithCoder(aCoder)
    }
}