
//  FolderService.swift
//  Fileeer
//
//  Created by Pavel Zaitsev on 2026-11-17.
//

import Foundation


final class FolderService {
    var url: URL?
    
    init(url: URL?){
        
        // Get the url from UserDefaults
        let r:Data = Data()
        let d = UserDefaults.standard
        self.url = url
        
        d.setValue(nil as Data?, forKey: "lastBookmark")
        d.bool(forKey: "lastBookmarkOk")
    }
    
    func permExec(writeUrl: URL?, writeData: () throws ->Void) -> URL? {
        
        // get the granted bookmark
        var d:UserDefaults = UserDefaults.standard
        var bkmk:Data? = d.data(forKey: "lastBookmark") ?? Data()
        var stale:Bool = d.bool(forKey: "lastBookmarkOk")
        var url:URL? =
            if bkmk != nil {
                try? URL(resolvingBookmarkData: bkmk ?? Data(), bookmarkDataIsStale:&stale)
            } else {
                writeUrl
            }
        
        // get perms and write stuff
        let granted = url?.startAccessingSecurityScopedResource()
        
        defer {
            if(granted ?? false){ url?.stopAccessingSecurityScopedResource()}
        }
        
        try writeData()
        return url
    }
}
