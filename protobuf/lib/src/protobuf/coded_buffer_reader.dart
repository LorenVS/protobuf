// Copyright (c) 2011, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

part of 'internal.dart';

/// Reader used for converting binary-encoded protobufs into
/// [GeneratedMessage]s.
class CodedBufferReader {
  // ignore: constant_identifier_names
  static const int DEFAULT_RECURSION_LIMIT = 64;
  // ignore: constant_identifier_names
  static const int DEFAULT_SIZE_LIMIT = 64 << 20;

  final Uint8List _buffer;
  int _bufferPos = 0;
  int _currentLimit = -1;
  int _lastTag = 0;
  int _recursionDepth = 0;
  final int _recursionLimit;
  final int _sizeLimit;

  CodedBufferReader(List<int> buffer,
      {int recursionLimit = DEFAULT_RECURSION_LIMIT,
      int sizeLimit = DEFAULT_SIZE_LIMIT})
      : _buffer = buffer is Uint8List ? buffer : Uint8List.fromList(buffer),
        _recursionLimit = recursionLimit,
        _sizeLimit = math.min(sizeLimit, buffer.length) {
    _currentLimit = _sizeLimit;
  }

  void _throwTruncatedMessageError(int limit) {
    if (limit > _sizeLimit && limit <= _buffer.length) {
      throw InvalidProtocolBufferException.truncatedMessageDueToSizeLimit(
          _buffer.length, _sizeLimit);
    }
    throw InvalidProtocolBufferException.truncatedMessage();
  }

  void checkLastTagWas(int value) {
    if (_lastTag != value) {
      throw InvalidProtocolBufferException.invalidEndTag();
    }
  }

  bool isAtEnd() => _bufferPos >= _currentLimit;

  void _withLimit(int byteLimit, Function() callback) {
    if (byteLimit < 0) {
      throw ArgumentError(
          'CodedBufferReader encountered an embedded string or message'
          ' which claimed to have negative size.');
    }
    byteLimit += _bufferPos;
    final oldLimit = _currentLimit;
    if ((oldLimit != -1 && byteLimit > oldLimit) || byteLimit > _sizeLimit) {
      _throwTruncatedMessageError(byteLimit);
    }
    _currentLimit = byteLimit;
    callback();
    _currentLimit = oldLimit;
  }

  void _checkLimit(int increment) {
    assert(_currentLimit != -1);
    _bufferPos += increment;
    if (_bufferPos > _currentLimit) {
      throw InvalidProtocolBufferException.truncatedMessage();
    }
  }

  void readGroup(int fieldNumber, GeneratedMessage message,
      ExtensionRegistry extensionRegistry) {
    if (_recursionDepth >= _recursionLimit) {
      throw InvalidProtocolBufferException.recursionLimitExceeded();
    }
    ++_recursionDepth;
    message.mergeFromCodedBufferReader(this, extensionRegistry);
    checkLastTagWas(makeTag(fieldNumber, WIRETYPE_END_GROUP));
    --_recursionDepth;
  }

  UnknownFieldSet readUnknownFieldSetGroup(int fieldNumber) {
    if (_recursionDepth >= _recursionLimit) {
      throw InvalidProtocolBufferException.recursionLimitExceeded();
    }
    ++_recursionDepth;
    final unknownFieldSet = UnknownFieldSet();
    unknownFieldSet.mergeFromCodedBufferReader(this);
    checkLastTagWas(makeTag(fieldNumber, WIRETYPE_END_GROUP));
    --_recursionDepth;
    return unknownFieldSet;
  }

  void readMessage(
      GeneratedMessage message, ExtensionRegistry extensionRegistry) {
    final length = readInt32();
    if (_recursionDepth >= _recursionLimit) {
      throw InvalidProtocolBufferException.recursionLimitExceeded();
    }
    if (length < 0) {
      throw ArgumentError(
          'CodedBufferReader encountered an embedded string or message'
          ' which claimed to have negative size.');
    }

    final oldLimit = _currentLimit;
    _currentLimit = _bufferPos + length;
    if (_currentLimit > oldLimit) {
      _throwTruncatedMessageError(_currentLimit);
    }
    ++_recursionDepth;
    message.mergeFromCodedBufferReader(this, extensionRegistry);
    checkLastTagWas(0);
    --_recursionDepth;
    _currentLimit = oldLimit;
  }

  int readEnum() => readInt32();
  int readInt32() => _readRawVarint32(true);
  Int64 readInt64() => _readRawVarint64();
  int readUint32() => _readRawVarint32(false);
  Int64 readUint64() => _readRawVarint64();
  int readSint32() => _decodeZigZag32(readUint32());
  Int64 readSint64() => _decodeZigZag64(readUint64());
  int readFixed32() => _readByteData(4).getUint32(0, Endian.little);
  Int64 readFixed64() => readSfixed64();
  int readSfixed32() => _readByteData(4).getInt32(0, Endian.little);
  Int64 readSfixed64() {
    final data = _readByteData(8);
    final view = Uint8List.view(data.buffer, data.offsetInBytes, 8);
    return Int64.fromBytes(view);
  }

  bool readBool() => _readRawVarint32(true) != 0;

  /// Read a length-delimited field as bytes.
  Uint8List readBytes() => Uint8List.fromList(readBytesAsView());

  /// Read a length-delimited field as a view of the [CodedBufferReader]'s
  /// buffer. When storing the returned value directly (instead of e.g. parsing
  /// it as a UTF-8 string and copying) use [readBytes] instead to avoid
  /// holding on to the whole message, or copy the returned view.
  Uint8List readBytesAsView() {
    final length = readInt32();
    _checkLimit(length);
    return Uint8List.view(
        _buffer.buffer, _buffer.offsetInBytes + _bufferPos - length, length);
  }

  String readString() => _utf8.decode(readBytesAsView());
  double readFloat() => _readByteData(4).getFloat32(0, Endian.little);
  double readDouble() => _readByteData(8).getFloat64(0, Endian.little);

  int readTag() {
    if (isAtEnd()) {
      _lastTag = 0;
      return 0;
    }

    _lastTag = readUint32();
    if (getTagFieldNumber(_lastTag) == 0) {
      throw InvalidProtocolBufferException.invalidTag();
    }
    return _lastTag;
  }

  bool skipField(int tag) {
    final tagType = getTagWireType(tag);

    if (isAtEnd() || tagType == WIRETYPE_END_GROUP) {
      return false;
    }

    switch (getTagWireType(tag)) {
      case WIRETYPE_VARINT:
        readInt64();
        return true;
      case WIRETYPE_FIXED64:
        readFixed64();
        return true;
      case WIRETYPE_LENGTH_DELIMITED:
        readBytesAsView();
        return true;
      case WIRETYPE_FIXED32:
        readFixed32();
        return true;
      case WIRETYPE_START_GROUP:
        readUnknownFieldSetGroup(getTagFieldNumber(tag));
        return true;
      default:
        throw InvalidProtocolBufferException.invalidWireType();
    }
  }

  static int _decodeZigZag32(int value) {
    if ((value & 0x1) == 1) {
      return -(value >> 1) - 1;
    } else {
      return value >> 1;
    }
  }

  static Int64 _decodeZigZag64(Int64 value) {
    if ((value & 0x1) == 1) value = -value;
    return value >> 1;
  }

  int _readRawVarintByte() {
    _checkLimit(1);
    return _buffer[_bufferPos - 1];
  }

  int _readRawVarint32(bool signed) {
    // Read up to 10 bytes.
    // We use a local [bufferPos] variable to avoid repeatedly loading/store the
    // this._bufferpos field.
    var bufferPos = _bufferPos;
    var bytes = _currentLimit - bufferPos;
    if (bytes > 10) bytes = 10;
    var result = 0;
    for (var i = 0; i < bytes; i++) {
      final byte = _buffer[bufferPos++];
      result |= (byte & 0x7f) << (i * 7);
      if ((byte & 0x80) == 0) {
        result &= 0xffffffff;
        _bufferPos = bufferPos;
        return signed ? result - 2 * (0x80000000 & result) : result;
      }
    }
    _bufferPos = bufferPos;
    throw InvalidProtocolBufferException.malformedVarint();
  }

  Int64 _readRawVarint64() {
    var lo = 0;
    var hi = 0;

    // Read low 28 bits.
    for (var i = 0; i < 4; i++) {
      final byte = _readRawVarintByte();
      lo |= (byte & 0x7f) << (i * 7);
      if ((byte & 0x80) == 0) return Int64.fromInts(hi, lo);
    }

    // Read middle 7 bits: 4 low belong to low part above,
    // 3 remaining belong to hi.
    final byte = _readRawVarintByte();
    lo |= (byte & 0xf) << 28;
    hi = (byte >> 4) & 0x7;
    if ((byte & 0x80) == 0) {
      return Int64.fromInts(hi, lo);
    }

    // Read remaining bits of hi.
    for (var i = 0; i < 5; i++) {
      final byte = _readRawVarintByte();
      hi |= (byte & 0x7f) << ((i * 7) + 3);
      if ((byte & 0x80) == 0) return Int64.fromInts(hi, lo);
    }
    throw InvalidProtocolBufferException.malformedVarint();
  }

  ByteData _readByteData(int sizeInBytes) {
    _checkLimit(sizeInBytes);
    return ByteData.view(_buffer.buffer,
        _buffer.offsetInBytes + _bufferPos - sizeInBytes, sizeInBytes);
  }
}
