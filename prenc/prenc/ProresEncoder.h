// Copyright (C) 2016 Netflix, Inc.
//
//     This file is part of OS X ProRes encoder.
//
//     OS X ProRes encoder is free software: you can redistribute it and/or modify
//     it under the terms of the GNU General Public License as published by
//     the Free Software Foundation, either version 3 of the License, or
//     (at your option) any later version.
//
//     OS X ProRes encoder is distributed in the hope that it will be useful,
//     but WITHOUT ANY WARRANTY; without even the implied warranty of
//     MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//     GNU General Public License for more details.
//
//     You should have received a copy of the GNU General Public License
//     along with OS X ProRes encoder.  If not, see <http://www.gnu.org/licenses/>.
//
//  ProresEncoder.h
//  prenc
//

#ifndef ProresEncoder_h
#define ProresEncoder_h

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <VideoToolbox/VTCompressionSession.h>


/**
 * ProresEncoder provides access to VideoToolbox ProRes encoder.
 */
@interface ProresEncoder : NSObject

/**
 * Initializes encoder with video settings.
 *
 * @param width frame width
 * @param height frame height
 * @param tsNum timescale numerator (1001/30000)
 * @param tsDen timescale denumerator (1001/30000)
 * @param darNum display aspect ratio numerator
 * @param darDen display aspect ratio denumerator
 * @param interlace interlaced video or not
 * @param enableHwAccelerated enable HW accelerated
 * @param highQualityFlag if YES the encoder will expect kCVPixelFormatType_4444AYpCbCr16 and will produce 12-bit ProRes 444
 * @param verifyOutput if YES and highQualityFlag is also YES the returned object will create a decoder, decode frames immediately after they've been encoded, and calculate the MSE and PSNR per-frame by comparing the raw frames to the decoded frames.  this is substantially slower.
 *
 * @return initialized ProresEncoder instance, nil otherwise
 */
- (id)initWithWidth:(int)width
             height:(int)height
              tsNum:(uint32_t)tsNum
              tsDen:(uint32_t)tsDen
             darNum:(uint32_t)darNum
             darDen:(uint32_t)darDen
          interlace:(BOOL)interlace
enableHwAccelerated:(BOOL)enableHwAccelerated
    highQualityFlag:(BOOL)hqFlag
       verifyOutput:(BOOL)verify;

/**
 * Encodes YUV 4:2:2 16-bit image data and puts result to internal buffer.
 *
 * @param rawimg YUV 4:2:2 16-bit image data pointer
 * @return YES on success encoding, NO otherwise
 */
- (BOOL)encodeWithRawImage:(uint8_t *)rawimg;

/**
 * Encodes the passed CVPixelBufferRef
 * 
 * @param n the CVPixelBufferRef you want to encode.  probably either kCVPixelFormatType_422YpCbCr16 or kCVPixelFormatType_4444AYpCbCr16.
 * @return YES on success encoding, NO otherwise
 */
- (BOOL)encodePixelBufferRef:(CVPixelBufferRef)n;

/**
 * Gets encoded frame from internal queue.
 *
 * @return Core Media sample buffer with encoded data if exists or nil if no frames
 */
- (CMSampleBufferRef)nextEncodedFrame;

/**
 * Flushes encoder data.
 *
 * return YES on success, NO otherwise
 */
- (BOOL)flushFrames;

@end


#endif /* ProresEncoder_h */
