//
//  Module.swift
//  NozeIO
//
//  Created by Helge Heß on 4/3/16.
//  Copyright © 2016 ZeeZide GmbH. All rights reserved.
//

import core
import events

public class NozeStreams : NozeModule, EventEmitterType {
  
  lazy var newReadableListeners =
    EventListenerSet<ReadableStreamType>(queueLength: 0)
  lazy var newWritableListeners =
    EventListenerSet<WritableStreamType>(queueLength: 0)
  
  public func onNewReadable(cb: ( ReadableStreamType ) -> Void) -> Self {
    newReadableListeners.add(handler: cb)
    return self
  }
  
  public func onNewWritable(cb: ( WritableStreamType ) -> Void) -> Self {
    newWritableListeners.add(handler: cb)
    return self
  }
}

public let module = NozeStreams()


// MARK: - Global Events

#if swift(>=3.0)
public func onNewReadable(_ cb: ( ReadableStreamType ) -> Void) -> NozeStreams {
  return module.onNewReadable(cb: cb)
}
public func onNewWritable(_ cb: ( WritableStreamType ) -> Void) -> NozeStreams {
  return module.onNewWritable(cb: cb)
}
#else
public func onNewReadable(cb: ( ReadableStreamType ) -> Void) -> NozeStreams {
  return module.onNewReadable(cb)
}
public func onNewWritable(cb: ( WritableStreamType ) -> Void) -> NozeStreams {
  return module.onNewWritable(cb)
}
#endif


// MARK: - Strings

// We use properties to avoid the need to use () when piping through it. Is this
// decent? Note sure, I guess conceptually no :-)
// TBD: A disadvantage is that we cannot use type overloading, i.e.
//        func utf8() -> TransformStream<String,    UInt8>
//        func utf8() -> TransformStream<Character, UInt8>

/// Consume bytes and produces String lines separated by newline (10)
public var readlines : TransformStream<UInt8, String> {
  return UTF8ToLines()
}

public var uniq : TransformStream<String, String> {
  return UniqStrings()
}

/// Consumes bytes and produces Characters from that.
public var utf8 : TransformStream<UInt8, Character> {
  return UTF8ToCharacter()
}
/// Consumes Characters and produces UTF-8 encoded bytes from that.
public var toUTF8 : TransformStream<Character, UInt8> {
  return CharacterToUTF8()
}



// MARK: - Concat

/// Returns a Writable which concats all data written into one big array. If
/// it is ended, it calls the doneCB with all the data.
///
/// Note: Useful for testing, but usually you don't want to buffer stuff up,
///       but - stream, boy, stream!
public func concat<T>(doneCB: ( [ T ] ) -> Void)
            -> TargetStream<ConcatTarget<T>>
{
  return ConcatTarget<T>(doneCB).writable(hwm: 1 /* hwm */)
}
