//
//  NetTCP.swift
//  PerfectLib
//
//  Created by Kyle Jessup on 7/5/15.
//	Copyright (C) 2015 PerfectlySoft, Inc.
//
//	This program is free software: you can redistribute it and/or modify
//	it under the terms of the GNU Affero General Public License as
//	published by the Free Software Foundation, either version 3 of the
//	License, or (at your option) any later version, as supplemented by the
//	Perfect Additional Terms.
//
//	This program is distributed in the hope that it will be useful,
//	but WITHOUT ANY WARRANTY; without even the implied warranty of
//	MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//	GNU Affero General Public License, as supplemented by the
//	Perfect Additional Terms, for more details.
//
//	You should have received a copy of the GNU Affero General Public License
//	and the Perfect Additional Terms that immediately follow the terms and
//	conditions of the GNU Affero General Public License along with this
//	program. If not, see <http://www.perfect.org/AGPL_3_0_With_Perfect_Additional_Terms.txt>.
//


import Dispatch
import Darwin

/// Provides an asynchronous IO wrapper around a file descriptor.
/// Fully realized for TCP socket types but can also serve as a base for sockets from other families, such as with `NetNamedPipe`/AF_UNIX.
public class NetTCP : Closeable {
	
	private var networkFailure: Bool = false
	private var semaphore: dispatch_semaphore_t?
	private var waitAcceptEvent: LibEvent?
	
	class ReferenceBuffer {
		var b: UnsafeMutablePointer<UInt8>
		let size: Int
		init(size: Int) {
			self.size = size
			self.b = UnsafeMutablePointer<UInt8>.alloc(size)
		}
		
		deinit {
			self.b.destroy()
			self.b.dealloc(self.size)
		}
	}
	
	var fd: SocketFileDescriptor = SocketFileDescriptor(fd: invalidSocket, family: AF_UNSPEC)
	
	/// Create a new object with an initially invalid socket file descriptor.
	public init() {
		
	}
	
	/// Creates an instance which will use the given file descriptor
	/// - parameter fd: The pre-existing file descriptor
	public convenience init(fd: Int32) {
		self.init()
		self.fd.fd = fd
		self.fd.family = AF_INET
		self.fd.switchToNBIO()
	}
	
	/// Allocates a new socket if it has not already been done.
	/// The functions `bind` and `connect` will call this method to ensure the socket has been allocated.
	/// Sub-classes should override this function in order to create their specialized socket.
	/// All sub-class sockets should be switched to utilize non-blocking IO by calling `SocketFileDescriptor.switchToNBIO()`.
	public func initSocket() {
		if fd.fd == invalidSocket {
			fd.fd = socket(AF_INET, SOCK_STREAM, 0)
			fd.family = AF_INET
			fd.switchToNBIO()
		}
	}
	
	func isEAgain(err: Int) -> Bool {
		return err == -1 && errno == EAGAIN
	}
	
	func evWhatFor(operation: Int32) -> Int32 {
		return operation
	}
	
	/// Bind the socket on the given port and optional local address
	/// - parameter port: The port on which to bind
	/// - parameter address: The the local address, given as a string, on which to bind. Defaults to "0.0.0.0".
	/// - throws: PerfectError.NetworkError
	public func bind(port: UInt16, address: String = "0.0.0.0") throws {
		
		initSocket()
		
		var addr: sockaddr_in = sockaddr_in()
		let res = makeAddress(&addr, host: address, port: port)
		guard res != -1 else {
			try ThrowNetworkError()
		}
		var sock_addr = sockaddr(sa_len: 0, sa_family: 0, sa_data: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
		memcpy(&sock_addr, &addr, Int(sizeof(sockaddr_in)))
		
		let bRes = Darwin.bind(fd.fd, &sock_addr, socklen_t(sizeof(sockaddr_in)))
		if bRes == -1 {
			try ThrowNetworkError()
		}
	}
	
	/// Switches the socket to server mode. Socket should have been previously bound using the `bind` function.
	public func listen(backlog: Int32 = 128) {
		Darwin.listen(fd.fd, backlog)
	}
	
	/// Shuts down and closes the socket.
	/// The object may be reused.
	public func close() {
		if fd.fd != invalidSocket {
			Darwin.shutdown(fd.fd, SHUT_RDWR)
			Darwin.close(fd.fd)
			fd.fd = invalidSocket
			
			if let event = self.waitAcceptEvent {
				event.del()
				self.waitAcceptEvent = nil
			}
			
			if self.semaphore != nil {
				dispatch_semaphore_signal(self.semaphore!)
			}
		}
	}
	
	func recv(buf: UnsafeMutablePointer<Void>, count: Int) -> Int {
		return Darwin.recv(self.fd.fd, buf, count, 0)
	}
	
	func send(buf: UnsafePointer<Void>, count: Int) -> Int {
		return Darwin.send(self.fd.fd, buf, count, 0)
	}
	
	private func makeAddress(inout sin: sockaddr_in, host: String, port: UInt16) -> Int {
		let theHost: UnsafeMutablePointer<hostent> = gethostbyname(host)
		if theHost == nil {
			if inet_addr(host) == INADDR_NONE {
				endhostent()
				return -1
			}
		}
		let bPort = port.bigEndian
		sin.sin_port = in_port_t(bPort)
		sin.sin_family = sa_family_t(AF_INET)
		if theHost != nil {
			sin.sin_addr.s_addr = UnsafeMutablePointer<UInt32>(theHost.memory.h_addr_list.memory).memory
		} else {
			sin.sin_addr.s_addr = inet_addr(host)
		}
		endhostent()
		return 0
	}
	
	private func completeArray(from: ReferenceBuffer, count: Int) -> [UInt8] {
		
		var ary = [UInt8](count: count, repeatedValue: 0)
		for index in 0..<count {
			ary[index] = from.b[index]
		}
		return ary
	}
	
	func readBytesFully(into: ReferenceBuffer, read: Int, remaining: Int, timeoutSeconds: Double, completion: ([UInt8]?) -> ()) {
		let readCount = recv(into.b + read, count: remaining)
		if readCount == 0 {
			completion(nil) // disconnect
		} else if self.isEAgain(readCount) {
			
			// no data available. wait
			self.readBytesFullyIncomplete(into, read: read, remaining: remaining, timeoutSeconds: timeoutSeconds, completion: completion)
			
		} else if readCount == -1 {
			completion(nil) // networking or other error
		} else {
			
			// got some data
			if remaining - readCount == 0 { // done
				completion(completeArray(into, count: read + readCount))
			} else { // try again for more
				readBytesFully(into, read: read + readCount, remaining: remaining - readCount, timeoutSeconds: timeoutSeconds, completion: completion)
			}
		}
	}
	
	func readBytesFullyIncomplete(into: ReferenceBuffer, read: Int, remaining: Int, timeoutSeconds: Double, completion: ([UInt8]?) -> ()) {
		let event: LibEvent = LibEvent(base: LibEvent.eventBase, fd: fd.fd, what: EV_READ, userData: nil) {
			(fd:Int32, w:Int16, ud:AnyObject?) -> () in
			
			if (Int32(w) & EV_TIMEOUT) == 0 {
				self.readBytesFully(into, read: read, remaining: remaining, timeoutSeconds: timeoutSeconds, completion: completion)
			} else {
				completion(nil) // timeout or error
			}
		}
		event.add(timeoutSeconds)
	}
	
	/// Read the indicated number of bytes and deliver them on the provided callback.
	/// - parameter count: The number of bytes to read
	/// - parameter timeoutSeconds: The number of seconds to wait for the requested number of bytes. A timeout value of negative one indicates that the request should have no timeout.
	/// - parameter completion: The callback on which the results will be delivered. If the timeout occurs before the requested number of bytes have been read, a nil object will be delivered to the callback.
	public func readBytesFully(count: Int, timeoutSeconds: Double, completion: ([UInt8]?) -> ()) {

		let ptr = ReferenceBuffer(size: count)
		readBytesFully(ptr, read: 0, remaining: count, timeoutSeconds: timeoutSeconds, completion: completion)
	}
	
	/// Read up to the indicated number of bytes and deliver them on the provided callback.
	/// - parameter count: The maximum number of bytes to read.
	/// - parameter completion: The callback on which to deliver the results. If an error occurs during the read then a nil object will be passed to the callback, otherwise, the immediately available number of bytes, which may be zero, will be passed.
	public func readSomeBytes(count: Int, completion: ([UInt8]?) -> ()) {
		
		let ptr = ReferenceBuffer(size: count)
		let readCount = recv(ptr.b, count: count)
		if readCount == 0 {
			completion(nil)
		} else if self.isEAgain(readCount) {
			completion([UInt8]())
		} else if readCount == -1 {
			completion(nil)
		} else {
			completion(completeArray(ptr, count: readCount))
		}
	}
	
	/// Write the string and call the callback with the number of bytes which were written.
	/// - parameter s: The string to write. The string will be written based on its UTF-8 encoding.
	/// - parameter completion: The callback which will be called once the write has completed. The callback will be passed the number of bytes which were successfuly written, which may be zero.
	public func write(s: String, completion: (Int) -> ()) {
		writeBytes([UInt8](s.utf8), completion: completion)
	}
	
	/// Write the indicated bytes and call the callback with the number of bytes which were written.
	/// - parameter bytes: The array of UInt8 to write.
	/// - parameter completion: The callback which will be called once the write has completed. The callback will be passed the number of bytes which were successfuly written, which may be zero.
	public func write(bytes: [UInt8], completion: (Int) -> ()) {
		writeBytes(bytes, dataPosition: 0, length: bytes.count, completion: completion)
	}
	
	/// Write the string and call the callback with the number of bytes which were written.
	/// - parameter s: The string to write. The string will be written based on its UTF-8 encoding.
	/// - parameter completion: The callback which will be called once the write has completed. The callback will be passed the number of bytes which were successfuly written, which may be zero.
	public func writeString(s: String, completion: (Int) -> ()) {
		writeBytes([UInt8](s.utf8), completion: completion)
	}
	
	/// Write the indicated bytes and call the callback with the number of bytes which were written.
	/// - parameter bytes: The array of UInt8 to write.
	/// - parameter completion: The callback which will be called once the write has completed. The callback will be passed the number of bytes which were successfuly written, which may be zero.
	public func writeBytes(bytes: [UInt8], completion: (Int) -> ()) {
		writeBytes(bytes, dataPosition: 0, length: bytes.count, completion: completion)
	}
	
	/// Write the indicated bytes and return true if all data was sent.
	/// - parameter bytes: The array of UInt8 to write.
	public func writeBytesFully(bytes: [UInt8]) -> Bool {
		let length = bytes.count
		var totalSent = 0
		let ptr = UnsafeMutablePointer<UInt8>(bytes)
		var s: dispatch_semaphore_t?
		var what: Int32 = 0
		
		let waitFunc = {
			let event: LibEvent = LibEvent(base: LibEvent.eventBase, fd: self.fd.fd, what: EV_WRITE, userData: nil) {
				(fd:Int32, w:Int16, ud:AnyObject?) -> () in
				what = Int32(w)
				dispatch_semaphore_signal(s!)
			}
			event.add()
		}
		
		while length > 0 {
			
			let sent = send(ptr.advancedBy(totalSent), count: length - totalSent)
			if sent == length {
				return true
			}
			
			if s == nil {
				s = dispatch_semaphore_create(0)
			}
			
			if sent == -1 {
				if isEAgain(sent) { // flow
					waitFunc()
				} else { // error
					break
				}
			} else {
				totalSent += sent
				
				if totalSent == length {
					return true
				}
				
				waitFunc()
			}
			
			dispatch_semaphore_wait(s!, DISPATCH_TIME_FOREVER)
			
			if what != EV_WRITE {
				break
			}
		}
		return totalSent == length
	}
			 
	/// Write the indicated bytes and call the callback with the number of bytes which were written.
	/// - parameter bytes: The array of UInt8 to write.
	/// - parameter dataPosition: The offset within `bytes` at which to begin writing.
	/// - parameter length: The number of bytes to write.
	/// - parameter completion: The callback which will be called once the write has completed. The callback will be passed the number of bytes which were successfuly written, which may be zero.
	public func writeBytes(bytes: [UInt8], dataPosition: Int, length: Int, completion: (Int) -> ()) {
		
		let ptr = UnsafeMutablePointer<UInt8>(bytes).advancedBy(dataPosition)
		writeBytes(ptr, wrote: 0, length: length, completion: completion)
	}
	
	func writeBytes(ptr: UnsafeMutablePointer<UInt8>, wrote: Int, length: Int, completion: (Int) -> ()) {
		let sent = send(ptr, count: length)
		if isEAgain(sent) {
			writeBytesIncomplete(ptr, wrote: wrote, length: length, completion: completion)
		} else if sent == -1 {
			completion(sent)
		} else if sent < length {
			// flow control
			writeBytesIncomplete(ptr.advancedBy(sent), wrote: wrote + sent, length: length - sent, completion: completion)
		} else {
			completion(wrote + sent)
		}
	}
	
	func writeBytesIncomplete(nptr: UnsafeMutablePointer<UInt8>, wrote: Int, length: Int, completion: (Int) -> ()) {
		let event: LibEvent = LibEvent(base: LibEvent.eventBase, fd: fd.fd, what: EV_WRITE, userData: nil) {
			(fd:Int32, w:Int16, ud:AnyObject?) -> () in
			
			self.writeBytes(nptr, wrote: wrote, length: length, completion: completion)
		}
		event.add()
	}
	
	/// Connect to the indicated server
	/// - parameter address: The server's address, expressed as a string.
	/// - parameter port: The port on which to connect.
	/// - parameter timeoutSeconds: The number of seconds to wait for the connection to complete. A timeout of negative one indicates that there is no timeout.
	/// - parameter callBack: The closure which will be called when the connection completes. If the connection completes successfully then the current NetTCP instance will be passed to the callback, otherwise, a nil object will be passed.
	/// - returns: `PerfectError.NetworkError`
	public func connect(address: String, port: UInt16, timeoutSeconds: Double, callBack: (NetTCP?) -> ()) throws {
		
		initSocket()
		
		var addr: sockaddr_in = sockaddr_in()
		let res = makeAddress(&addr, host: address, port: port)
		guard res != -1 else {
			try ThrowNetworkError()
		}
		var sock_addr = sockaddr(sa_len: 0, sa_family: 0, sa_data: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
		memcpy(&sock_addr, &addr, Int(sizeof(sockaddr_in)))
		
		let cRes = Darwin.connect(fd.fd, &sock_addr, socklen_t(sizeof(sockaddr_in)))
		if cRes != -1 {
			callBack(self)
		} else {
			guard errno == EINPROGRESS else {
				try ThrowNetworkError()
			}
			
			let event: LibEvent = LibEvent(base: LibEvent.eventBase, fd: fd.fd, what: EV_WRITE, userData: nil) {
				(fd:Int32, w:Int16, ud:AnyObject?) -> () in
				
				if (Int32(w) & EV_TIMEOUT) != 0 {
					callBack(nil)
				} else {
					callBack(self)
				}
			}
			event.add(timeoutSeconds)
		}
	}
	
	/// Accept a new client connection and pass the result to the callback.
	/// - parameter timeoutSeconds: The number of seconds to wait for a new connection to arrive. A timeout value of negative one indicates that there is no timeout.
	/// - parameter callBack: The closure which will be called when the accept completes. the parameter will be a newly allocated instance of NetTCP which represents the client.
	/// - returns: `PerfectError.NetworkError`
	public func accept(timeoutSeconds: Double, callBack: (NetTCP?) -> ()) throws {
		let accRes = Darwin.accept(fd.fd, UnsafeMutablePointer<sockaddr>(), UnsafeMutablePointer<socklen_t>())
		if accRes != -1 {
			let newTcp = self.makeFromFd(accRes)
			callBack(newTcp)
		} else {
			guard self.isEAgain(Int(accRes)) else {
				try ThrowNetworkError()
			}
			
			let event: LibEvent = LibEvent(base: LibEvent.eventBase, fd: fd.fd, what: self.evWhatFor(EV_READ), userData: nil) {
				(fd:Int32, w:Int16, ud:AnyObject?) -> () in
				
				if (Int32(w) & EV_TIMEOUT) != 0 {
					callBack(nil)
				} else {
					do {
						try self.accept(timeoutSeconds, callBack: callBack)
					} catch {
						callBack(nil)
					}
				}
			}
			event.add(timeoutSeconds)
		}
	}
	
	private func tryAccept() -> Int32 {
		let accRes = Darwin.accept(fd.fd, UnsafeMutablePointer<sockaddr>(), UnsafeMutablePointer<socklen_t>())
		return accRes
	}
	
	private func waitAccept() {
		let event: LibEvent = LibEvent(base: LibEvent.eventBase, fd: fd.fd, what: self.evWhatFor(EV_READ), userData: nil) {
			(fd:Int32, w:Int16, ud:AnyObject?) -> () in
			
			self.waitAcceptEvent = nil
			if (Int32(w) & EV_TIMEOUT) != 0 {
				print("huh?")
			} else {
				dispatch_semaphore_signal(self.semaphore!)
			}
		}
		self.waitAcceptEvent = event
		event.add()
	}
	
	/// Accept a series of new client connections and pass them to the callback. This function does not return outside of a catastrophic error.
	/// - parameter callBack: The closure which will be called when the accept completes. the parameter will be a newly allocated instance of NetTCP which represents the client.
	public func forEachAccept(callBack: (NetTCP?) -> ()) {
		
		guard self.semaphore == nil else {
			return
		}
		
		self.semaphore = dispatch_semaphore_create(0)
		defer { self.semaphore = nil }
		
		repeat {
		
			let accRes = tryAccept()
			if accRes != -1 {
				split_thread {
					callBack(self.makeFromFd(accRes))
				}
			} else if self.isEAgain(Int(accRes)) {
				waitAccept()
				dispatch_semaphore_wait(self.semaphore!, DISPATCH_TIME_FOREVER)
			} else {
				let errStr = String.fromCString(strerror(errno)) ?? "NO MESSAGE"
				print("Unexpected networking error: \(errno) '\(errStr)'")
				networkFailure = true
			}
		} while !networkFailure && self.fd.fd != invalidSocket
		return
	}
	
	func makeFromFd(fd: Int32) -> NetTCP {
		return NetTCP(fd: fd)
	}
}





