//
//  GCDChannelBase.swift
//  NozeIO
//
//  Created by Helge Hess on 28/07/15.
//  Copyright © 2015 ZeeZide GmbH. All rights reserved.
//

import Dispatch
import xsys
import core

private let DISPATCH_DATA_DESTRUCTOR_DEFAULT : dispatch_block_t! = nil

private let logTraffic = false
private let debugClose = false

/// Abstract base class. Already implements both, the reading and writing
/// base functions (to easily create Duplex streams). It does NOT implement the
/// respective protocol, so that subclasses can choose what they actually
/// support.
///
/// # Source
///
/// A source which provides arrays of bytes by reading from a Unix file
/// descriptor.
/// Subclasses of this source (like a FileSource or SocketSource) usually
/// determine how the file descriptor itself is build/derived.
///
/// Be a bit careful on how NIO works on Unix. The major thing to keep in mind
/// is that (unlike sockets or pipes) files do NOT provide NIO on Unix.
/// Descriptors refering to actual files are always 'Readable' and a read will
/// always read (& block until at least some data is available), not just copy
/// the receive buffer like with sockets.
///
/// FIXME: The byte buffer implementation seems to be a major performance bug in
///        this implementation.
///
public class GCDChannelBase: CustomStringConvertible {
  
  public typealias SourceElement = UInt8
  public typealias TargetElement = UInt8
  
  public let log = Logger(enabled: false)
  
  // Note: This is not necessarily set! E.g. the FileSource directly creates
  //       a channel from a path.
  public var fd  : FileDescriptor
  
#if os(Linux) // yeah, that is a little weird.
#if swift(>=3.0) // #swift3-fd
  public var channel : dispatch_io_t! = nil
#else
  public var channel : dispatch_io_t = nil
#endif
#else
  public var channel : dispatch_io_t! = nil
#endif
  
  let shouldClose = true

  
  // MARK: - init & teardown
  
  public init(_ fd: FileDescriptor) {
    self.fd = fd
    
    log.onAfterEnter  = { [weak self] log in self?.logState() }
    log.onBeforeLeave = { [weak self] log in self?.logState() }
  }
  public convenience init(fd: Int32) {
    let fdo = FileDescriptor(fd)
    self.init(fdo)
  }
  deinit {
    teardown()
  }
  
  
  // MARK: - Channel Management
  
  public var isShuttingDown = false
  
  public func finishedLastWrite() {
    assert(writesPending == 0)
    if isShuttingDown {
      if channel != nil {
        dispatch_io_close(channel, DISPATCH_IO_STOP)
        channel = nil
      }
    }
  }
  
  public func teardown() {
    log.enter(); defer { log.leave() }
    isShuttingDown = true
    
    if channel != nil {
      // FIXME: we probably don't want to DISPATCH_IO_STOP if writes are pending
      if writesPending == 0 {
        // stop pending reads.
        dispatch_io_close(channel, DISPATCH_IO_STOP) // TBD: DISPATCH_IO_STOP
        channel = nil
      }
    }
    else if shouldClose && fd.isValid {
      fd.close()
      fd = -1
    }
  }
  
  public func cleanupChannel(error: Int32) {
    // called if the channel is destroyed
    // NOTE: This is also called if opening a file failed (i.e. in FileSource,
    //       Target)
    if error != 0 {
      self.handleError(error: error)
    }
    
    if self.shouldClose && self.fd.isValid {
      self.fd.close()
      self.fd = -1
    }
    
    /*
    // TBD: reset channel or not? (ARC issue?)
    channel = nil
     */
  }
  
  public func createChannelIfMissing(Q q: dispatch_queue_t) -> ErrorType? {
    guard fd.isValid     else { return POSIXError.EINVAL }
    guard channel == nil else { return nil }
    
    channel = dispatch_io_create(DISPATCH_IO_STREAM, fd.fd, q, cleanupChannel)
    guard channel != nil else { return POSIXError(rawValue: xsys.errno) }
    
    // Essentially GCD channels already implement a buffer very similar to
    // Node.JS. But we do it on our own. Hence make GCD report input ASAP.
    dispatch_io_set_low_water(channel, 1)

    return nil
  }
  
  
  // MARK: - Closing
  
  public func closeSource() {
    if debugClose { print("CLOSE SOURCE (BOTH): \(self)") }
    closeBoth()
  }
  public func closeTarget() {
    if debugClose { print("CLOSE TARGET (BOTH): \(self)") }
    closeBoth()
  }
  public func closeBoth() {
    if debugClose { print("CLOSE BOTH: \(self)") }
    teardown()
  }
  
  
  // MARK: - Errors
  
  public var pendingErrors = [ ErrorType ]() // #linux-public
  
  public func handleError(error e: Int32) {
    // The sources/targets do not maintain a references to their associated
    // channel. They can only report stuff when the respective entry function
    // is being called.
    // Hence we need to queue up errors, and deliver them as we get called.
    
    log.log("error: \(e)")
    
    if readsPending < 1 && writesPending < 1 {
      // otherwise the callback will get the error from GCD
      pendingErrors.append(POSIXError(rawValue: e)!)
      // This does happen with testReadStream404WithConcatPipe, might be a race
      // assert(false, "GCD OOM error")
    }
  }
  
  public var hitEOF = false
  
  
  // MARK: - Readable Entry Point
  
  public var readsPending = 0

  public func next(queue Q : dispatch_queue_t, count: Int,
                   yield   : ( ErrorType?, [ SourceElement ]? )-> Void)
  {
    let log = self.log
    log.enter(function: "GCDChannelSource::\(#function)");
    defer { log.leave() }
    
    
    // errors which came in while we haven't been listening.
    for error in pendingErrors {
      yield(error, nil)
    }
    pendingErrors.removeAll()
    
    
    guard !hitEOF else {
      yield(nil, nil) // EOF
      return
    }
    
    assert(count > 0)
    let howMuchToRead = count > 0 ? count : 1
    
    
    // Note: this ties us to that queue
    if let error = createChannelIfMissing(Q: Q) {
      yield(error, nil)
      return
    }
    
    
    log.debug("asked to read #bytes: \(howMuchToRead) " +
              "(NIO: \(fd.isNonBlocking)) ...")
    
    readsPending += 1 // should that only ever be 1?
    dispatch_io_read(channel, 0, howMuchToRead, Q) {
      done, pdata, error in

      self.readsPending -= 1
      
      log.enter(function: "GCDChannelSource::\(#function)");
      defer { log.leave() }
      
      // NOTE: EOF is data == dispatch_data_empty, NOT nil
      
      if pdata != nil {
#if os(Linux)
#if swift(>=3.0) // #swift3-fd
        let data = pdata!
#else
        let data = pdata
#endif
	let hitEOF : Bool
	if error == 0 && done {
	  // not strideof in this case, right?
	  var mdata1 = data, mdata2 = dispatch_data_empty
	  // TBD: just cast to a pointer?
	  hitEOF = memcmp(&mdata1, &mdata2, sizeof(dispatch_data_t)) == 0
	}
	else {
	  hitEOF = false
	}
#else // OSX
        let data = pdata!
	let hitEOF = data === dispatch_data_empty && error == 0 && done
#endif // OSX

        if hitEOF {
          log.debug("EOF.")
          self.hitEOF = true
          yield(nil, nil) // EOF
          return
        }
        
        log.debug("walk data ...")
        let ok = dispatch_data_apply(data) {
          subdata, offset, ptr, len in
          
          log.enter(function: "GCDChannelTarget::\(#function)");
          defer { log.leave() }
          
          // hack. ugly copying
#if swift(>=3.0) // #swift3-fd
          var array = ByteBucket(repeating: 0, count: len)
#if os(Linux)
          _ = memcpy(&array, ptr!, len)
#else
          _ = memcpy(&array, ptr, len)
#endif
#else
          var array = ByteBucket(count: len, repeatedValue: 0)
          memcpy(&array, ptr, len)
#endif
          
          yield(nil, array)
          
          return true // continue block
        }
        assert(ok)
      }
      
      if error != 0 {
        if self.channel == nil  && error == POSIXError.ECANCELED.rawValue {
          // this error is due to the source being shut down. For example, if
          // a Socket is closed.
          
          // TBD: maybe this is not sufficient and a plain bug. Who knows.
          log.debug("EOF on shutodwn.")
          self.hitEOF = true
          yield(nil, nil) // send EOF
        }
        else {
          // TODO: emit proper error when POSIXError does not construct
          log.log("ERROR: \(self) \(error)")
          yield(POSIXError(rawValue: error)!, nil)
        }
      }
      
      if done {
        // this is not necessarily EOF, just this chunk has been fully
        // processed. No more CBs coming (for this dispatch_io_read)
      }
    }
  }
  
  
  // MARK: - WritableTargetType
  
  public var writesPending = 0

  public func writev(queue Q : dispatch_queue_t,
                     chunks  : [ ByteBucket ],
                     yield   : ( ErrorType?, Int ) -> Void)
  {
    let log = self.log
    log.enter(function: "GCDChannelTarget::\(#function)");
    defer { log.leave() }
    
    // Note: this ties us to that queue
    if let error = createChannelIfMissing(Q: Q) {
      yield(error, 0)
      return
    }
    
    // DEBUG
    if logTraffic || log.enabled {
      for bucket in chunks {
        var s = debugBucketAsString(bucket: bucket)
        print("  BUCKET:\(s) #\(bucket.count)")
      }
    }
    
    
    /* convert brigade into dispatch_data */
    
    var data : dispatch_data_t? = nil
    for chunk in chunks {
      guard !chunk.isEmpty else { continue }
      
      // TODO: copies data, could we just capture the chunks?
#if swift(>=3.0) // #swift3-gcd
      let lChunkData = dispatch_data_create(chunk, chunk.count, Q,
                                            DISPATCH_DATA_DESTRUCTOR_DEFAULT)
      guard let chunkData = lChunkData else {
        yield(POSIXError.ENOMEM, 0)
        return
      }
#else
      let chunkData = dispatch_data_create(chunk, chunk.count, Q,
                                           DISPATCH_DATA_DESTRUCTOR_DEFAULT)
#endif
      if let head = data {
        data = dispatch_data_create_concat(head, chunkData)
      }
      else {
        data = chunkData
      }
    }
    
    assert(data != nil, "Got no data to write?")
    guard data != nil else {
      yield(nil, 0)
      return
    }
    
    let count = dispatch_data_get_size(data!)
    log.debug("asked to write #\(count) bytes ...")
    
    
    /* schedule write */
    
    writesPending += 1
      // There can be more than one, but I guess that is inefficient.
    
    dispatch_io_write(channel, 0, data!, Q) {
      done, pendingData, error in

      self.writesPending -= 1
      
      log.enter(function: "GCDChannelTarget::\(#function)");
      defer { log.leave() }

      // TBD: EOF on socket shutdown? (done=YES,error=0,data=zero-data)

#if os(Linux)
      let pendingSize : size_t
      if pendingData != nil {
#if swift(>=3.0) // #swift3-gcd
        pendingSize = dispatch_data_get_size(pendingData!)
#else
        pendingSize = dispatch_data_get_size(pendingData)
#endif
      }
      else { pendingSize = 0 }
#else
      let pendingSize =
            pendingData != nil ? dispatch_data_get_size(pendingData!) : 0
#endif
      log.debug("pending: #\(pendingSize) bytes ..")
      
      if error != 0 {
        // TODO: emit proper error when POSIXError does not construct
        // TODO: properly count the bytes which got written successfully
        log.debug("error: \(error)")
        yield(POSIXError(rawValue: error)!, count - pendingSize)
      }
      else if done {
        log.debug("done writing \(count) bytes.")
        yield(nil, count)
      }
      
      if self.writesPending == 0 {
        self.finishedLastWrite()
      }
    }
  }
  
  
  // MARK: - Description
  
  public var logStateInfo : String {
    var s = ""

    if fd.isValid {
      if      fd.fd == xsys.STDIN_FILENO  { s += " stdin"  }
      else if fd.fd == xsys.STDOUT_FILENO { s += " stdout" }
      else if fd.fd == xsys.STDERR_FILENO { s += " stderr" }
      else { s += "fd=\(fd.fd)" }
    }
    else          { s += "-" }
    
    if hitEOF         { s += " EOF"        }
    if channel == nil { s += " no-channel" }
    if !shouldClose   { s += " unowned"    }
    
    if readsPending  > 0 { s += " #reads=\(readsPending)"   }
    if writesPending > 0 { s += " #writes=\(writesPending)" }
    
    return s
  }
  
  public func logState() {
    log.debug("[\(logStateInfo )]")
  }
  
  public var description : String {
    return "<\(self.dynamicType):\(descriptionAttributes())>"
  }
  
  // must live in the main-class as 'declarations in extensions cannot be
  // overridden yet' (Same in Swift 2.0)
  public func descriptionAttributes() -> String {
    return " " + logStateInfo
  }
}

#if os(Linux)
  import Glibc
#endif

func debugBucketAsString(bucket b: [ UInt8 ]) -> String {
  var s = ""
  for c in b {
    if isprint(Int32(c)) != 0 {
      s += " \(UnicodeScalar(c))"
    }
    else {
      s += " \\\(c)"
    }
  }
  return s
}
