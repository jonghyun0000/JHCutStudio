import Foundation
import Darwin

/// No replacement, including ExFAT which does not implement RENAME_EXCL/hard links.
public enum ExclusivePublication {
    static func error(_ url: URL, _ code: Int32 = errno) -> NSError { NSError(domain:NSPOSIXErrorDomain,code:Int(code),userInfo:[NSFilePathErrorKey:url.path]) }
    static func same(_ fd:Int32,_ name:String,_ identity:stat)->Bool {
        var current=stat();return fstatat(fd,name,&current,AT_SYMLINK_NOFOLLOW)==0 && current.st_dev==identity.st_dev && current.st_ino==identity.st_ino
    }
    public static func file(from source:URL,to destination:URL,check:() throws -> Void = {try Task.checkCancellation()})throws {
        try check()
        if renamex_np(source.path,destination.path,UInt32(RENAME_EXCL))==0 {return}
        let failure=errno
        guard failure==ENOTSUP else{throw error(destination,failure)}
        let parent=open(destination.deletingLastPathComponent().path,O_RDONLY|O_DIRECTORY);guard parent>=0 else{throw error(destination)};defer{close(parent)}
        try copy(source,to:parent,name:destination.lastPathComponent,check:check)
    }
    /// Flat immutable bundles; the integrity manifest is copied LAST in the ExFAT fallback.
    /// Readers only accept manifest-verified bundles. Existing destinations are never replaced.
    public static func directory(from source:URL,to destination:URL,manifest:String,check:() throws -> Void = {try Task.checkCancellation()})throws {
        try check()
        if renamex_np(source.path,destination.path,UInt32(RENAME_EXCL))==0 {return}
        let failure=errno;guard failure==ENOTSUP else{throw error(destination,failure)}
        let parent=open(destination.deletingLastPathComponent().path,O_RDONLY|O_DIRECTORY);guard parent>=0 else{throw error(destination)};defer{close(parent)}
        let name=destination.lastPathComponent
        guard mkdirat(parent,name,0o700)==0 else{throw error(destination)}
        var identity=stat();guard fstatat(parent,name,&identity,AT_SYMLINK_NOFOLLOW)==0 else{throw error(destination)}
        let fd=openat(parent,name,O_RDONLY|O_DIRECTORY|O_NOFOLLOW);guard fd>=0 else{throw error(destination)};defer{close(fd)}
        var entries:[(String,stat)]=[];var complete=false
        defer {
            if !complete {
                for (name,id) in entries.reversed() where same(fd,name,id){_ = unlinkat(fd,name,0)}
                if same(parent,name,identity){_ = unlinkat(parent,name,AT_REMOVEDIR)}
            }
        }
        let names=try FileManager.default.contentsOfDirectory(atPath:source.path).filter{$0 != manifest}.sorted()+[manifest]
        for name in names {
            try copy(source.appendingPathComponent(name),to:fd,name:name,check:check)
            var id=stat();guard fstatat(fd,name,&id,AT_SYMLINK_NOFOLLOW)==0 else{throw error(destination)};entries.append((name,id))
        }
        try check();guard same(parent,name,identity),entries.allSatisfy({same(fd,$0.0,$0.1)}) else{throw ProjectError("게시 중 대상 폴더가 변경되었습니다.")}
        complete=true
    }
    static func copy(_ source:URL,to parent:Int32,name:String,check:() throws -> Void)throws {
        let fd=openat(parent,name,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0o600);guard fd>=0 else{throw error(source)}
        var identity=stat();guard fstat(fd,&identity)==0 else{close(fd);throw error(source)}
        var complete=false
        defer {
            _ = fsync(fd);var updated=stat();if fstat(fd,&updated)==0{identity=updated};close(fd)
            if !complete && same(parent,name,identity){_ = unlinkat(parent,name,0)}
        }
        let input=try FileHandle(forReadingFrom:source);defer{try? input.close()}
        while let bytes=try input.read(upToCount:1_048_576),!bytes.isEmpty {
            try check()
            try bytes.withUnsafeBytes { raw in
                var offset=0
                while offset<raw.count {
                    let count=Darwin.write(fd,raw.baseAddress!.advanced(by:offset),raw.count-offset)
                    if count<0 && errno==EINTR{continue}
                    guard count>0 else{throw error(source)};offset+=count
                }
            }
        }
        try check();guard fsync(fd)==0 else{throw error(source)}
        var final=stat();guard fstat(fd,&final)==0, same(parent,name,final) else{throw ProjectError("게시 중 파일이 변경되었습니다.")}
        complete=true
    }
}

/// Cleanup is tied to the exact private directory inode, not a prefix or destination name.
public final class ExportWorkspace {
    public let url:URL
    private var identity:stat
    public init(parent:URL,id:UUID)throws {
        url=parent.appendingPathComponent(".JHCut-delivery-\(id.uuidString).partial",isDirectory:true)
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:false)
        var info=stat();guard lstat(url.path,&info)==0 else{throw ExclusivePublication.error(url)};identity=info
    }
    public func cleanup(){var current=stat();if lstat(url.path,&current)==0,current.st_dev==identity.st_dev,current.st_ino==identity.st_ino{try? FileManager.default.removeItem(at:url)}}
}
