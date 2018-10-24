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
//  ProresEncoder.m
//  prenc
//

#import "ProresEncoder.h"

#import <VideoToolbox/VTCompressionSession.h>
#import <VideoToolbox/VTDecompressionSession.h>
#import <VideoToolbox/VTProfessionalVideoWorkflow.h>
#import <VideoToolbox/VTVideoEncoderList.h>
#import <pthread.h>
#import "math.h"

#include <set>




//	this class records the number of times a value appears (used to calculate statistics about changes to pixel values during encoding)
class DeltaCount	{
public:
	int32_t		value;
	int			count = 1;
	
	DeltaCount(const int32_t & n) : value(n) {}
	DeltaCount(const DeltaCount & n) : value(n.value), count(n.count) {}
	friend bool operator==(const DeltaCount & a, const DeltaCount & b) { return (a.value==b.value); }
	friend bool operator<(const DeltaCount & a, const DeltaCount & b) { return (a.value<b.value); }
	friend bool operator>(const DeltaCount & a, const DeltaCount & b) { return (a.value>b.value); }
	void increment() { ++count; }
};




@interface ProresEncoder ()

@property (nonatomic)         VTCompressionSessionRef   compSess;
@property (nonatomic)         VTDecompressionSessionRef decompSess;

@property (nonatomic)         CFMutableArrayRef         encodedQueue;
@property (nonatomic)         CFMutableArrayRef         comparisonQueueSrc;
@property (nonatomic)         CFMutableArrayRef         comparisonQueueDst;

@property (nonatomic)         int                       width;
@property (nonatomic)         int                       height;

@property (nonatomic)         CMTimeScale               tsNum;
@property (nonatomic)         CMTimeScale               tsDen;

@property (nonatomic)         BOOL                      hqFlag;
@property (nonatomic)         BOOL                      verifyFlag;

@property (nonatomic)         uint64_t                  frameNumber;

@property (nonatomic)         pthread_mutex_t           *queueMutex;

- (void) _finishedEncodingFrame:(CMSampleBufferRef)n;
- (void) _finishedDecodingFrame:(CVImageBufferRef)n;

@end




static void pixelBufferReleaseCb(void *releaseRefCon, const void *baseAddress)
{
    free(releaseRefCon);
}

static void frameEncodedCb(
                           void *outputCallbackRefCon,
                           void *sourceFrameRefCon,
                           OSStatus status,
                           VTEncodeInfoFlags infoFlags,
                           CMSampleBufferRef sampleBuffer)
{
    ProresEncoder *encoder = (__bridge ProresEncoder *)outputCallbackRefCon;

    if (status != noErr || sampleBuffer == NULL)
        return;
    
    [encoder _finishedEncodingFrame:sampleBuffer];
}




@implementation ProresEncoder

+ (void) initialize {
    VTRegisterProfessionalVideoWorkflowVideoEncoders();
    VTRegisterProfessionalVideoWorkflowVideoDecoders();
}

- (id)init
{
    return [self initWithWidth:1920
                        height:1080
                         tsNum:1
                         tsDen:30
                        darNum:16
                        darDen:9
                     interlace:NO
           enableHwAccelerated:YES
               highQualityFlag:NO
                  verifyOutput:NO];
}

- (id)initWithWidth:(int)width
             height:(int)height
              tsNum:(uint32_t)tsNum
              tsDen:(uint32_t)tsDen
             darNum:(uint32_t)darNum
             darDen:(uint32_t)darDen
          interlace:(BOOL)interlace
enableHwAccelerated:(BOOL)enableHwAccelerated
    highQualityFlag:(BOOL)hqFlag
       verifyOutput:(BOOL)verify
{
    int ret = 0;
    CFMutableDictionaryRef encoderSpecification = NULL;
    CFMutableDictionaryRef decoderSpecification = NULL;
    CFMutableDictionaryRef dstImgFmt = NULL;

    if ((self = [super init]) == nil)
        return nil;

    self.frameNumber = 0;
    self.width = width;
    self.height = height;

    self.tsNum = tsNum;
    self.tsDen = tsDen;
    
    self.hqFlag = hqFlag;
    self.verifyFlag = verify;

    self.encodedQueue = CFArrayCreateMutable(kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks);
    self.comparisonQueueSrc = CFArrayCreateMutable(kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks);
    self.comparisonQueueDst = CFArrayCreateMutable(kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks);

    _queueMutex = static_cast<pthread_mutex_t*>(malloc(sizeof(pthread_mutex_t)));
    if (pthread_mutex_init(_queueMutex, NULL))
    {
        fprintf(stderr, "Cannot create queue mutex.\n");
        return nil;
    }
    
    encoderSpecification = CFDictionaryCreateMutable(
        kCFAllocatorDefault,
        1,
        &kCFCopyStringDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks);
    decoderSpecification = CFDictionaryCreateMutable(
        kCFAllocatorDefault,
        1,
        &kCFCopyStringDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks);
    dstImgFmt = CFDictionaryCreateMutable(
        kCFAllocatorDefault,
        1,
        &kCFCopyStringDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks);
    
    // create compression (encoding) session
    if (enableHwAccelerated)
    {
        if (encoderSpecification && decoderSpecification)
        {
            CFDictionarySetValue(
                                 encoderSpecification,
                                 kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder,
                                 kCFBooleanTrue);
            CFDictionarySetValue(
                                 decoderSpecification,
                                 kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder,
                                 kCFBooleanTrue);
        }
        else
        {
            fprintf(stderr, "Hardware acceleration property cannot be created.\n");
        }
    }
    if (self.hqFlag)
    {
        if (encoderSpecification && decoderSpecification)
        {
            CFDictionarySetValue(
                encoderSpecification,
                kVTCompressionPropertyKey_Depth,
                (__bridge const void *)([NSNumber numberWithInteger:12]));
            CFDictionarySetValue(
                decoderSpecification,
                kVTCompressionPropertyKey_Depth,
                (__bridge const void *)([NSNumber numberWithInteger:12]));
            //NSLog(@"\t\tencoder spec is %@",encoderSpecification);
        }
        else
        {
            fprintf(stderr, "compression bit depth property cannot be created.\n");
        }
    }
    
    if (CFDictionaryGetCount(encoderSpecification) < 1)
        encoderSpecification = NULL;
    if (CFDictionaryGetCount(decoderSpecification) < 1)
        decoderSpecification = NULL;
    
    if (self.hqFlag)
    {
        ret = VTCompressionSessionCreate(
            NULL,
            self.width,
            self.height,
            kCMVideoCodecType_AppleProRes4444,
            encoderSpecification,
            NULL,
            NULL,
            frameEncodedCb,
            (__bridge void *)self,
            &_compSess);
    }
    else
    {
        ret = VTCompressionSessionCreate(
            NULL,                               /* allocator                   */
            self.width,                         /* width                       */
            self.height,                        /* height                      */
            kCMVideoCodecType_AppleProRes422HQ, /* codecType                   */
            encoderSpecification,               /* encoderSpecification        */
            NULL,                               /* sourceImageBufferAttributes */
            NULL,                               /* compressedDataAllocator     */
            frameEncodedCb,                     /* outputCallback              */
            (__bridge void *)self,              /* outputCallbackRefCon        */
            &_compSess);                        /* compressionSessionOut       */
    }
    
    if (ret)
    {
        fprintf(stderr, "ProRes encoder cannot be created. Internal error %d.\n", ret);
        return nil;
    }
    
    if (VTSessionSetProperty(_compSess, kVTCompressionPropertyKey_RealTime, kCFBooleanFalse))
        fprintf(stderr, "Encoder real-time mode cannot be disabled.\n");
    
    
    //  if we're supposed to be verifying the encoded data, create a decompression session
    if (self.verifyFlag)
    {
        OSStatus                        osErr = noErr;
        CMVideoFormatDescriptionRef     fmtDescRef = NULL;
        if (self.hqFlag)
        {
            osErr = CMVideoFormatDescriptionCreate(
                NULL,                               /* allocator */
                kCMVideoCodecType_AppleProRes4444,  /* codec type */
                self.width,                         /* width */
                self.height,                        /* height */
                NULL,                               /* extension */
                &fmtDescRef);                       /* description out */
        
            if (osErr != noErr)
            {
                fprintf(stderr, "ProRes fmt desc cannot be created, err %d\n",osErr);
                return nil;
            }
        
            CFDictionarySetValue(dstImgFmt, kCVPixelBufferPixelFormatTypeKey, (__bridge const void *)([NSNumber numberWithInteger:kCVPixelFormatType_4444AYpCbCr16]));
        }
        else
        {
            osErr = CMVideoFormatDescriptionCreate(
                NULL,                               /* allocator */
                kCMVideoCodecType_AppleProRes422HQ,  /* codec type */
                self.width,                         /* width */
                self.height,                        /* height */
                NULL,                               /* extension */
                &fmtDescRef);                       /* description out */
        
            if (osErr != noErr)
            {
                fprintf(stderr, "ProRes fmt desc cannot be created, err %d\n",osErr);
                return nil;
            }
        
            CFDictionarySetValue(dstImgFmt, kCVPixelBufferPixelFormatTypeKey, (__bridge const void *)([NSNumber numberWithInteger:kCVPixelFormatType_422YpCbCr16]));
        }
    
    
        CFNumberRef widthNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &_width);
        CFNumberRef heightNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &_height);
    
        CFDictionarySetValue(dstImgFmt, kCVPixelBufferWidthKey, widthNum);
        CFDictionarySetValue(dstImgFmt, kCVPixelBufferHeightKey, heightNum);
    
        CFRelease(widthNum);
        CFRelease(heightNum);
    
        ret = VTDecompressionSessionCreate(
            kCFAllocatorDefault,                    /* allocator */
            fmtDescRef,                             /* video format description */
            decoderSpecification,                   /* video decoder specification */
            dstImgFmt,                              /* destination image buffer attribs */
            NULL,                                   /* output callback */
            &_decompSess);                          /* decompression session out */
        if (ret)
        {
            fprintf(stderr, "ProRes decoder cannot be created. Internal error %d.\n", ret);
            return nil;
        }
    
        if (VTSessionSetProperty(_decompSess, kVTCompressionPropertyKey_RealTime, kCFBooleanFalse))
            fprintf(stderr, "Decoder real-time mode cannot be disabled.\n");
    }
    
    // set pixel aspect ratio
    ret = [self setPixelAspectRatioWithFrameWidth:self.width
                                      frameHeight:self.height
                                           darNum:darNum
                                           darDen:darDen];
    if (ret)
        fprintf(stderr, "Aspect ratio property (%d:%d) cannot be set (%d).\n", darNum, darDen, ret);

    // set interlace mode if necessary
    if (interlace)
    {
        ret = [self setInterlaceMode];
        if (ret)
            fprintf(stderr, "Cannot set interlace video property (%d).\n", ret);
    }

    return self;
}

- (void)dealloc
{
    if (_compSess)
    {
        VTCompressionSessionInvalidate(_compSess);
        CFRelease(_compSess);
    }
    
    if (_decompSess)
    {
        VTDecompressionSessionInvalidate(_decompSess);
        CFRelease(_decompSess);
    }

    if (_queueMutex)
    {
        pthread_mutex_destroy(_queueMutex);
        free(_queueMutex);
    }

    if (_encodedQueue)
    {
        CMSampleBufferRef buf;
        while ((buf = [self nextEncodedFrame]))
            CFRelease(buf);

        CFRelease(_encodedQueue);
    }
    
    if (_comparisonQueueSrc)
    {
        CFArrayRemoveAllValues(_comparisonQueueSrc);
        CFRelease(_comparisonQueueSrc);
        _comparisonQueueSrc = NULL;
    }
    
    if (_comparisonQueueDst)
    {
        CFArrayRemoveAllValues(_comparisonQueueDst);
        CFRelease(_comparisonQueueDst);
        _comparisonQueueDst = NULL;
    }
}

- (BOOL)encodeWithRawImage:(uint8_t *)rawimg
{
    int ret = 0;
    CVPixelBufferRef pixBuf = NULL;
    
    if (self.hqFlag)    {
        ret = CVPixelBufferCreateWithBytes(
            NULL,
            self.width,
            self.height,
            kCVPixelFormatType_4444AYpCbCr16,
            rawimg,
            self.width * 64 / 8,
            pixelBufferReleaseCb,
            rawimg,
            NULL,
            &pixBuf);
    }
    else    {
        ret = CVPixelBufferCreateWithBytes(
            NULL,
            self.width,
            self.height,
            kCVPixelFormatType_422YpCbCr16,
            rawimg,
            self.width * 4,
            pixelBufferReleaseCb,
            rawimg,
            NULL,
            &pixBuf);
    
    }
    
    ret = [self encodePixelBufferRef:pixBuf];
    
    if (pixBuf)
        CFRelease(pixBuf);
    
    return ret;
    
}
- (BOOL)encodePixelBufferRef:(CVPixelBufferRef)n
{
    if (n == NULL)
        return NO;
    
    CMTime pts = CMTimeMake(self.frameNumber * self.tsNum, self.tsDen);
    int ret = 0;
    
    if (_verifyFlag)    {
        pthread_mutex_lock(_queueMutex);
        CFArrayAppendValue(_comparisonQueueSrc, n);
        pthread_mutex_unlock(_queueMutex);
    }

    ret = VTCompressionSessionEncodeFrame(_compSess, n, pts, kCMTimeInvalid, NULL, NULL, NULL);
    if (ret)
        goto done;

    self.frameNumber++;

done:
    
    return (BOOL)!ret;
}

- (void) _finishedEncodingFrame:(CMSampleBufferRef)n    {
    CMSampleBufferRef encodedSampleBuffer = NULL;
    if (CMSampleBufferCreateCopy(kCFAllocatorDefault, n, &encodedSampleBuffer))
    {
        fprintf(stderr, "Cannot create encoded sample buffer.\n");
        return;
    }

    pthread_mutex_lock(_queueMutex);
    {
        CFArrayAppendValue(_encodedQueue, encodedSampleBuffer);
    }
    pthread_mutex_unlock(_queueMutex);
    
    
    if (_verifyFlag)    {
        OSStatus                osErr = noErr;
        __weak __block id       bss = (id)self;
    
        osErr = VTDecompressionSessionDecodeFrameWithOutputHandler(
            _decompSess,            /* decomp session */
            encodedSampleBuffer,    /* sample buffer */
            0,                      /* decode flags */
            NULL,                   /* info flags (out) */
            ^(OSStatus status, VTDecodeInfoFlags infoFlags, CVImageBufferRef imageBuffer, CMTime presentationTimeStamp, CMTime presentationDuration)    {
                //OSType        pxlFmtType = CVPixelBufferGetPixelFormatType(imageBuffer);
                //NSLog(@"\t\tpixel format of decoded is %@",NSFileTypeForHFSTypeCode(pxlFmtType));
                [bss _finishedDecodingFrame:imageBuffer];
            });
    }
}
- (void) _finishedDecodingFrame:(CVImageBufferRef)n {
	using namespace std;
	
    pthread_mutex_lock(_queueMutex);
    {
        CFArrayAppendValue(_comparisonQueueDst, n);
        //  while the comparison queues have items in them...
        while (CFArrayGetCount(_comparisonQueueSrc)>0 && CFArrayGetCount(_comparisonQueueDst)>0)    {
            
            //  pull buffers out of the comparison src and dst queues
            CVImageBufferRef        srcBuffer = (CVImageBufferRef)CFArrayGetValueAtIndex(_comparisonQueueSrc, 0);
            CVImageBufferRef        dstBuffer = (CVImageBufferRef)CFArrayGetValueAtIndex(_comparisonQueueDst, 0);
            
            CVPixelBufferLockBaseAddress(srcBuffer, 0);
            CVPixelBufferLockBaseAddress(dstBuffer, 0);
            
            //  fetch a bunch of properties of the src and dst buffers that we're going to need later
            OSType                  srcPixelFmt = CVPixelBufferGetPixelFormatType(srcBuffer);
            NSSize                  srcBufferSize = NSMakeSize(CVPixelBufferGetWidth(srcBuffer), CVPixelBufferGetHeight(srcBuffer));
            uint16_t                *srcBase = static_cast<uint16_t*>(CVPixelBufferGetBaseAddress(srcBuffer));
            size_t                  srcBytesPerRow = CVPixelBufferGetBytesPerRow(srcBuffer);
            
            OSType                  dstPixelFmt = CVPixelBufferGetPixelFormatType(dstBuffer);
            NSSize                  dstBufferSize = NSMakeSize(CVPixelBufferGetWidth(dstBuffer), CVPixelBufferGetHeight(dstBuffer));
            uint16_t                *dstBase = static_cast<uint16_t*>(CVPixelBufferGetBaseAddress(dstBuffer));
            size_t                  dstBytesPerRow = CVPixelBufferGetBytesPerRow(dstBuffer);
            
            //  if the buffers cannot be compared for some reason, get rid of them and proceed to the next buffer
            if (srcPixelFmt!=dstPixelFmt || !NSEqualSizes(srcBufferSize,dstBufferSize) || srcBase==NULL || dstBase==NULL || srcBytesPerRow==0 || dstBytesPerRow==0) {
                fprintf(stderr,"ERR cannot process frame, basic check failed.\n");
                NSLog(@"\tsrcPixelFmt=%@, dstPixelFmt=%@",NSFileTypeForHFSTypeCode(srcPixelFmt),NSFileTypeForHFSTypeCode(dstPixelFmt));
                NSLog(@"\tsrcBufferSize=%@, dstBufferSize=%@",NSStringFromSize(srcBufferSize),NSStringFromSize(dstBufferSize));
                NSLog(@"\tsrcBase=%p, dstBase=%p",srcBase,dstBase);
                NSLog(@"\tsrcBytesPerRow=%ld, dstBytesPerRow=%ld",srcBytesPerRow,dstBytesPerRow);
                
                CVPixelBufferUnlockBaseAddress(srcBuffer, 0);
                CVPixelBufferUnlockBaseAddress(dstBuffer, 0);
            
                CFArrayRemoveValueAtIndex(_comparisonQueueSrc, 0);
                CFArrayRemoveValueAtIndex(_comparisonQueueDst, 0);
                
                continue;
            }
            
            
            //  we're going to store the largest and smallest deltas, and this struct makes doing so cleaner
            typedef struct PixelColor   {
                int32_t y;
                int32_t cb;
                int32_t cr;
                int32_t a;
            } PixelColor;
            
            //	we're going to store the deltas for the luma channel in this set so we can calculate mean/median/mode
            std::set<DeltaCount>		deltaSet;
            
            /*  this could be optimized to reduce LOC and increase performance- but i'm leaving it 
            this to be understandable, and because this code is explicitly for non-production use...            */
            switch (srcPixelFmt)    {
            case kCVPixelFormatType_4444AYpCbCr16:
                {
                    BOOL        foundErr = NO;
                    uint64_t    tmpBigNum = 0;
                    
                    PixelColor  smallestDelta = { 0x7FFFFFFF, 0x7FFFFFFF, 0x7FFFFFFF, 0x7FFFFFFF };
                    PixelColor  largestDelta = { 0, 0, 0, 0 };
                    uint32_t    numberOfWrongPixels = 0;
                    
                    for (int row=0; row<srcBufferSize.height; ++row)    {
                        for (int col=0; col<srcBufferSize.width; ++col) {
                            //  16 bits per channel * 4 channels per "column" / 8 bits per byte / 2 bytes per uint16_t ptr
                            uint16_t        *srcPixel = srcBase + (((row*srcBytesPerRow) + (col * (16 * 4 / 8)))/2);
                            uint16_t        *dstPixel = dstBase + (((row*dstBytesPerRow) + (col * (16 * 4 / 8)))/2);
                            BOOL        foundPixelErr = NO;
                            
                            uint16_t        *srcA = srcPixel;
                            uint16_t        *srcY = srcA + 1;
                            uint16_t        *srcCb = srcY + 1;
                            uint16_t        *srcCr = srcCb + 1;
                            
                            uint16_t        *dstA = dstPixel;
                            uint16_t        *dstY = dstA + 1;
                            uint16_t        *dstCb = dstY + 1;
                            uint16_t        *dstCr = dstCb + 1;
                            
                            PixelColor      delta = { 0, 0, 0, 0 };
                            
                            delta.a = *dstA - *srcA;
                            if (delta.a != 0) {
                                foundPixelErr = YES;
                                //tmpBigNum += pow(delta.a,2);
                                if (abs(delta.a) > labs(largestDelta.a)) largestDelta.a = delta.a;
                                if (abs(delta.a) < labs(smallestDelta.a)) smallestDelta.a = delta.a;
                            }
                            
                            delta.y = *dstY - *srcY;
                            if (delta.y != 0) {
                                foundPixelErr = YES;
                                tmpBigNum += pow(delta.y,2);
                                if (abs(delta.y) > labs(largestDelta.y)) largestDelta.y = delta.y;
                                if (abs(delta.y) < labs(smallestDelta.y)) smallestDelta.y = delta.y;
                            }
                            
                            delta.cb = *dstCb - *srcCb;
                            if (delta.cb != 0) {
                                foundPixelErr = YES;
                                tmpBigNum += pow(delta.cb,2);
                                if (abs(delta.cb) > labs(largestDelta.cb)) largestDelta.cb = delta.cb;
                                if (abs(delta.cb) < labs(smallestDelta.cb)) smallestDelta.cb = delta.cb;
                            }
                            
                            delta.cr = *dstCr - *srcCr;
                            if (delta.cr != 0) {
                                foundPixelErr = YES;
                                tmpBigNum += pow(delta.cr,2);
                                if (abs(delta.cr) > labs(largestDelta.cr)) largestDelta.cr = delta.cr;
                                if (abs(delta.cr) < labs(smallestDelta.cr)) smallestDelta.cr = delta.cr;
                            }
							
							
							//	try to find a DeltaCount in the set that matches the luma channel's delta- add one if it doesn't exist, or increment the one that already exists
							if (delta.y != 0)	{
								auto		matchingDelta = deltaSet.find( DeltaCount(delta.y) );
								if (matchingDelta == deltaSet.end())
									deltaSet.insert( DeltaCount(delta.y) );
								else
									const_cast<DeltaCount&>(*matchingDelta).increment();
                            }
                            
                            if (foundPixelErr)  {
                                //fprintf(stderr, " {%d, %d, %d, %d}",delta.y,delta.cb,delta.cr,delta.a);
                                ++numberOfWrongPixels;
                                foundErr = YES;
                            }
                        }
                    }
                    
                    //	log the results of the comparison
                    if (!foundErr)
                        fprintf(stderr,"images are identical!\n");
                    else    {
                    	//	calculate the mean/median/mode
						int64_t			mean_cumulativeVal = 0;
						int				mode_maxValCount = 0;
						int32_t			mode_maxValCountVal = 0;
					
						for (const auto & tmpVal : deltaSet)	{
							mean_cumulativeVal += (tmpVal.value * tmpVal.count);
						
							if (tmpVal.count > mode_maxValCount)	{
								mode_maxValCount = tmpVal.count;
								mode_maxValCountVal = tmpVal.value;
							}
						}
						double			mean_val = double(mean_cumulativeVal) / double(CVPixelBufferGetWidth(srcBuffer) * CVPixelBufferGetHeight(srcBuffer));
						auto			median_it = deltaSet.lower_bound( int(deltaSet.size()/2) );
						int32_t			median_val = median_it->value;
						fprintf(stderr,"%ld different luma deltas found.  delta vals in 16-bit space (x/65535).\n",deltaSet.size());
						fprintf(stderr,"\tmean delta val is %0.2f, median delta val is %d, mode delta val is %d (%d occurrences).\n", 
							mean_val,
							median_val,
							mode_maxValCountVal,
							mode_maxValCount);
                    	
                    	//	calculate MSE and PSNR
                        //double      meanSquaredError = (double)tmpBigNum / (double)(CVPixelBufferGetWidth(srcBuffer) * CVPixelBufferGetHeight(srcBuffer) * 4);	//	this uses alpha to calculate PSNR (make sure you add alpha to 'tmpBigNum' if you use this!)
                        double      meanSquaredError = (double)tmpBigNum / (double)(CVPixelBufferGetWidth(srcBuffer) * CVPixelBufferGetHeight(srcBuffer) * 3);	//	this doesn't use alpha to calculate PSNR (make sure you don't add alpha to 'tmpBigNum' if you use this!)
                        double      psnr = (20.0 * log10((double)0xFFFF)) - (10.0 * log10(meanSquaredError));
                        fprintf(stderr,"\t%d total pixels had some kind of delta (luma or chroma). MSE is %0.2f, PSNR is %0.2f.\n",numberOfWrongPixels,meanSquaredError,psnr);
                        if (smallestDelta.y == 0x7FFFFFFF)
                            smallestDelta.y = 0;
                        if (smallestDelta.cb == 0x7FFFFFFF)
                            smallestDelta.cb = 0;
                        if (smallestDelta.cr == 0x7FFFFFFF)
                            smallestDelta.cr = 0;
                        if (smallestDelta.a == 0x7FFFFFFF)
                            smallestDelta.a = 0;
                        //fprintf(stderr,"smallestDelta:  %d  %d  %d  %d",smallestDelta.y,smallestDelta.cb,smallestDelta.cr,smallestDelta.a);
                        //fprintf(stderr,"  largestDelta:  %d  %d  %d  %d\n",largestDelta.y,largestDelta.cb,largestDelta.cr,largestDelta.a);
                    }
                }
                break;
            
            case kCVPixelFormatType_422YpCbCr16:
                {
                    BOOL        foundErr = NO;
                    uint64_t    tmpBigNum = 0;
                    
                    PixelColor  smallestDelta = { 0x7FFFFFFF, 0x7FFFFFFF, 0x7FFFFFFF, 0x7FFFFFFF };
                    PixelColor  largestDelta = { 0, 0, 0, 0 };
                    uint32_t    numberOfWrongPixels = 0;
                    
                    for (int row=0; row<srcBufferSize.height; ++row)    {
                        for (int col=0; col<srcBufferSize.width; ++col) {
                            //  16 bits per channel * 2 channels per "pixel" / 8 bits per byte / 2 bytes per uint16_t ptr
                            uint16_t        *srcPixel = srcBase + (((row*srcBytesPerRow) + (col * (16 * 2 / 8)))/2);
                            uint16_t        *dstPixel = dstBase + (((row*dstBytesPerRow) + (col * (16 * 2 / 8)))/2);
                            BOOL        foundPixelErr = NO;
                            
                            uint16_t        *srcColor = srcPixel;
                            uint16_t        *srcY = srcColor + 1;
                            
                            uint16_t        *dstColor = dstPixel;
                            uint16_t        *dstY = dstColor + 1;
                            
                            PixelColor      delta = { 0, 0, 0, 0 };
                            
                            
                            delta.y = *dstY - *srcY;
                            if (delta.y != 0) {
                                foundPixelErr = YES;
                                tmpBigNum += pow(delta.y,2);
                                if (abs(delta.y) > labs(largestDelta.y)) largestDelta.y = delta.y;
                                if (abs(delta.y) < labs(smallestDelta.y)) smallestDelta.y = delta.y;
                            }
                            
                            delta.cb = *dstColor - *srcColor;
                            if (delta.cb != 0) {
                                foundPixelErr = YES;
                                tmpBigNum += pow(delta.cb,2);
                                if (abs(delta.cb) > labs(largestDelta.cb)) largestDelta.cb = delta.cb;
                                if (abs(delta.cb) < labs(smallestDelta.cb)) smallestDelta.cb = delta.cb;
                            }
                            
                            
                            //	try to find a DeltaCount in the set that matches the luma channel's delta- add one if it doesn't exist, or increment the one that already exists
                            if (delta.y != 0)	{
								auto		matchingDelta = deltaSet.find( DeltaCount(delta.y) );
								if (matchingDelta == deltaSet.end())
									deltaSet.insert( DeltaCount(delta.y) );
								else
									const_cast<DeltaCount&>(*matchingDelta).increment();
                            }
                            
                            if (foundPixelErr)  {
                                //fprintf(stderr, " {%d, %d, %d, %d}",delta.y,delta.cb,delta.cr,delta.a);
                                ++numberOfWrongPixels;
                                foundErr = YES;
                            }
                        }
                    }
                    
                     //	log the results of the comparison
                    if (!foundErr)
                        fprintf(stderr,"images are identical!\n");
                    else    {
                    	//	calculate the mean/median/mode
						int64_t			mean_cumulativeVal = 0;
						int				mode_maxValCount = 0;
						int32_t			mode_maxValCountVal = 0;
					
						for (const auto & tmpVal : deltaSet)	{
							mean_cumulativeVal += (tmpVal.value * tmpVal.count);
						
							if (tmpVal.count > mode_maxValCount)	{
								mode_maxValCount = tmpVal.count;
								mode_maxValCountVal = tmpVal.value;
							}
						}
						double			mean_val = double(mean_cumulativeVal) / double(CVPixelBufferGetWidth(srcBuffer) * CVPixelBufferGetHeight(srcBuffer));
						auto			median_it = deltaSet.lower_bound( int(deltaSet.size()/2) );
						int32_t			median_val = median_it->value;
						fprintf(stderr,"%ld different luma deltas found.  delta vals in 16-bit space (x/65535).\n",deltaSet.size());
						fprintf(stderr,"\tmean delta val is %0.2f, median delta val is %d, mode delta val is %d (%d occurrences).\n", 
							mean_val,
							median_val,
							mode_maxValCountVal,
							mode_maxValCount);
                    	
                    	//	calculate MSE and PSNR
                        double      meanSquaredError = (double)tmpBigNum / (double)(CVPixelBufferGetWidth(srcBuffer) * CVPixelBufferGetHeight(srcBuffer) * 2);
                        double      psnr = (20.0 * log10((double)0xFFFF)) - (10.0 * log10(meanSquaredError));
                        fprintf(stderr,"\t%d total pixels had some kind of delta (luma or chroma). MSE is %0.2f, PSNR is %0.2f.\n",numberOfWrongPixels,meanSquaredError,psnr);
                        if (smallestDelta.y == 0x7FFFFFFF)
                            smallestDelta.y = 0;
                        if (smallestDelta.cb == 0x7FFFFFFF)
                            smallestDelta.cb = 0;
                        //fprintf(stderr,"smallestDelta:  %d  %d",smallestDelta.y,smallestDelta.cb);
                        //fprintf(stderr,"  largestDelta:  %d  %d\n",largestDelta.y,largestDelta.cb);
                    }
                }
                break;
            }
            
            
            CVPixelBufferUnlockBaseAddress(srcBuffer, 0);
            CVPixelBufferUnlockBaseAddress(dstBuffer, 0);
            
            CFArrayRemoveValueAtIndex(_comparisonQueueSrc, 0);
            CFArrayRemoveValueAtIndex(_comparisonQueueDst, 0);
        }
    }
    pthread_mutex_unlock(_queueMutex);
}

- (BOOL)hasEncodedFrame
{
    BOOL ret;
    pthread_mutex_lock(self.queueMutex);
    {
        ret = CFArrayGetCount(self.encodedQueue) > 0;
    }
    pthread_mutex_unlock(self.queueMutex);

    return ret;
}

- (CMSampleBufferRef)nextEncodedFrame
{
    if ([self hasEncodedFrame])
    {
        CMSampleBufferRef sampleBuffer;

        pthread_mutex_lock(self.queueMutex);
        {
            sampleBuffer = (CMSampleBufferRef)CFArrayGetValueAtIndex(self.encodedQueue, 0);
            CFArrayRemoveValueAtIndex(self.encodedQueue, 0);
        }
        pthread_mutex_unlock(self.queueMutex);

        return sampleBuffer;
    }
    else
        return NULL;
}

- (BOOL)flushFrames
{
    return (BOOL)!VTCompressionSessionCompleteFrames(_compSess, kCMTimeIndefinite);
}

- (OSStatus)setPixelAspectRatioWithFrameWidth:(int)frameWidth
    frameHeight:(int)frameHeight
    darNum:(int)darNum
    darDen:(int)darDen
{
    OSStatus ret = noErr;
    int numValue = darNum * frameHeight;
    int denValue = darDen * frameWidth;

    if (darNum <= 0 || darDen <= 0)
        return ret;

    if (numValue % denValue == 0 && numValue / denValue == 1)
        return ret;

    CFNumberRef parNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &numValue);
    CFNumberRef parDen = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &denValue);


    CFMutableDictionaryRef par = CFDictionaryCreateMutable(
        kCFAllocatorDefault,
        2,
        &kCFCopyStringDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks);
    
    if (parNum == NULL || parDen == NULL || par == NULL)
    {
        ret = -1;
        goto done;
    }

    CFDictionarySetValue(
        par,
        kCMFormatDescriptionKey_PixelAspectRatioHorizontalSpacing,
        parNum);

    CFDictionarySetValue(
        par,
        kCMFormatDescriptionKey_PixelAspectRatioVerticalSpacing,
        parDen);

    ret = VTSessionSetProperty(
        _compSess,
        kVTCompressionPropertyKey_PixelAspectRatio,
        par);
    if (ret != noErr)
        fprintf(stderr, "err: VTSessionSetProperty() returned %d in %s\n",(int)ret,__func__);
    
done:
    if (parNum)
        CFRelease(parNum);
    if (parDen)
        CFRelease(parDen);
    if (par)
        CFRelease(par);

    return ret;
}

- (OSStatus)setInterlaceMode
{
    OSStatus ret;
    int fieldValue = 2;
    CFNumberRef fieldCount = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &fieldValue);

    if (fieldCount == NULL)
    {
        ret = -1;
        goto done;
    }

    ret = VTSessionSetProperty(
                               _compSess,
                               kVTCompressionPropertyKey_FieldCount,
                               fieldCount);
    if (ret)
        goto done;

    ret = VTSessionSetProperty(
                               _compSess,
                               kVTCompressionPropertyKey_FieldDetail,
                               kCMFormatDescriptionFieldDetail_TemporalTopFirst);

done:
    if (fieldCount)
        CFRelease(fieldCount);

    return ret;
}

@end



