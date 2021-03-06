//
//  Bytes.swift
//  PerfectLib
//
//  Created by Kyle Jessup on 7/7/15.
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

/// A Bytes object represents an array of UInt8 and provides various utilities for importing and exporting values into and out of that array.
/// A Bytes object maintains a position marker which is used to denote the position from which new export operations proceed.
/// An export will advance the position by the appropriate amount.
public class Bytes {
	
	/// The position from which new export operations begin.
	public var position = 0
	/// The underlying UInt8 array
	public var data: [UInt8]
	
	/// Create an empty Bytes object
	public init() {
		self.data = [UInt8]()
	}
	
	/// Create a new Bytes object containing `initialSize` values of zero
	/// - parameter initialSize: The size of the initial array
	public init(initialSize: Int) {
		self.data = [UInt8](count: initialSize, repeatedValue: 0)
	}
	
	// -- IMPORT
	/// Imports one UInt8 value appending it to the end of the array
	/// - returns: The Bytes object
	public func import8Bits(byte: UInt8) -> Bytes {
		data.append(byte)
		return self
	}
	
	/// Imports one UInt16 value appending it to the end of the array
	/// - returns: The Bytes object
	public func import16Bits(short: UInt16) -> Bytes {
		data.append(UInt8(short & 0xFF))
		data.append(UInt8((short >> 8) & 0xFF))
		return self
	}
	
	/// Imports one UInt32 value appending it to the end of the array
	/// - returns: The Bytes object
	public func import32Bits(int: UInt32) -> Bytes {
		data.append(UInt8(int & 0xFF))
		data.append(UInt8((int >> 8) & 0xFF))
		data.append(UInt8((int >> 16) & 0xFF))
		data.append(UInt8((int >> 24) & 0xFF))
		return self
	}
	
	/// Imports one UInt64 value appending it to the end of the array
	/// - returns: The Bytes object
	public func import64Bits(int: UInt64) -> Bytes {
		data.append(UInt8(int & 0xFF))
		data.append(UInt8((int >> 8) & 0xFF))
		data.append(UInt8((int >> 16) & 0xFF))
		data.append(UInt8((int >> 24) & 0xFF))
		data.append(UInt8((int >> 32) & 0xFF))
		data.append(UInt8((int >> 40) & 0xFF))
		data.append(UInt8((int >> 48) & 0xFF))
		data.append(UInt8((int >> 56) & 0xFF))
		return self
	}
	
	/// Imports an array of UInt8 values appending them to the end of the array
	/// - returns: The Bytes object
	public func importBytes(bytes: [UInt8]) -> Bytes {
		data.appendContentsOf(bytes)
		return self
	}
	
	/// Imports the array values of the given Bytes appending them to the end of the array
	/// - returns: The Bytes object
	public func importBytes(bytes: Bytes) -> Bytes {
		data.appendContentsOf(bytes.data)
		return self
	}
	
	/// Imports an `ArraySlice` of UInt8 values appending them to the end of the array
	/// - returns: The Bytes object
	public func importBytes(bytes: ArraySlice<UInt8>) -> Bytes {
		data.appendContentsOf(bytes)
		return self
	}
	
	// -- EXPORT
	
	/// Exports one UInt8 from the current position. Advances the position marker by 1 byte.
	/// - returns: The UInt8 value
	public func export8Bits() -> UInt8 {
		return data[position++]
	}
	
	/// Exports one UInt16 from the current position. Advances the position marker by 2 bytes.
	/// - returns: The UInt16 value
	public func export16Bits() -> UInt16 {
		let one = UInt16(data[position++])
		let two = UInt16(data[position++])
		
		return (two << 8) + one
	}
	
	/// Exports one UInt32 from the current position. Advances the position marker by 4 bytes.
	/// - returns: The UInt32 value
	public func export32Bits() -> UInt32 {
		let one = UInt32(data[position++])
		let two = UInt32(data[position++])
		let three = UInt32(data[position++])
		let four = UInt32(data[position++])
		
		return (four << 24) + (three << 16) + (two << 8) + one
	}
	
	/// Exports one UInt64 from the current position. Advances the position marker by 8 bytes.
	/// - returns: The UInt64 value
	public func export64Bits() -> UInt64 {
		let one = UInt64(data[position++])
		let two = UInt64(data[position++]) << 8
		let three = UInt64(data[position++]) << 16
		let four = UInt64(data[position++]) << 24
		let five = UInt64(data[position++]) << 32
		let six = UInt64(data[position++]) << 40
		let seven = UInt64(data[position++]) << 48
		let eight = UInt64(data[position++]) << 56
		
		return (one+two+three+four)+(five+six+seven+eight)
	}
}
















