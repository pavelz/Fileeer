
//  FolderService.swift
//  Fileeer
//
//  Created by Pavel Zaitsev on 2026-11-17.
//

import Foundation


final class FolderService {
    
    init(){
        // Get the url from UserDefaults
        let r:Data = Data()
        let d = UserDefaults.standard
        d.setValue("localhost", forKey: "lastBookmark")
        d.bool(forKey: "lastBookmarkOk")
    }
    
    func getPermissions() -> String {
        var d:UserDefaults = UserDefaults.standard
        var bkmk:Data? = d.data(forKey: "lastBookmark") ?? Data()
        var stale:Bool = d.bool(forKey: "lastBookmarkOk")
        var url:URL? = try? URL(resolvingBookmarkData: bkmk ?? Data(), bookmarkDataIsStale:&stale)
 
        print("hello\n")
        defer { print("hey ho\n") }
        return ""
    }
}
