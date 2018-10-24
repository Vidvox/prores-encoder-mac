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
//  prenc.m
//  prenc
//

#include <unistd.h>
#include <stdlib.h>
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <getopt.h>
#include <libgen.h>

#import "ProresEncoder.h"
#import "MovieWriter.h"


#define FORMAT_SCALE_STR     "scale="
#define FORMAT_DAR_STR       "setdar="
#define FORMAT_FPS_STR       "fps="
#define FORMAT_INTERLACE_STR "interlace"

/**
 * Prints usage of application.
 *
 * @param programName program name
 */
static void printUsage(char *programName)
{
    char *name = basename(programName);

    printf("Usage: %s [OPTION]... FILE\n", name);
    printf("Encode YUV 4:2:2 16-bit planar source from file\n"
           "or standard input to QuickTime Movie FILE using ProRes 422 HQ codec.\n");
    printf("Examples:\n");
    printf("  %s -i test.yuv -f scale=720:480,setdar=4/3,fps=30000/1001,interlace test.mov\n", name);
    printf("  %s -i test.yuv -f scale=720:480,setdar=4/3,fps=30000/1001,interlace test.mov -p yuv444p16le\n", name);
    printf("  %s -i test.yuv -f scale=720:480,setdar=4/3,fps=30000/1001,interlace test.mov -v -p yuv444p16le\n", name);
    printf("\n");
    printf("Options:\n");
    printf("  -i, --input=YUV_FILE    ""Input file with valid planar YUV 4:2:2 16-bit content.\n");
    printf("  -f, --format=FORMAT     ""Specific conversion video format settings, comma as delimeter.\n");
    printf("                            default scale=1920:1080,fps=30/1\n");
    printf("  -h, --help              ""Print this help.\n");
    printf("  -p, --pix_fmt=FORMAT    ""Sets the expected input format.\n");
    printf("  -v, --verify            ""Decodes the encoded buffers immediately, logs MSE and PSNR on a \n");
    printf("                          ""per-frame basis to stdout. Slower.\n");
    printf("  -t, --test              ""Test mode- 10/12 bit gradients are encoded instead of input frames \n");
    printf("                          ""so the codec's image precision can be tested (try using with -v)\n");
    printf("\n");
    printf("Format settings:\n");
    printf("  scale=WIDTH:HEIGHT      ""Sets frame size, default 1920x1080.\n");
    printf("  setdar=NUM:DEN          ""Sets display aspect ratio, default set by encoder.\n");
    printf("  fps=NUM:DEN             ""Sets video frame rate, default 30fps\n");
    printf("  interlace               ""Sets interlaced video, default progressive.\n");
    printf("\n");
    printf("Pixel Format Settings:\n");
    printf("  yuv422p16le             ""Default value.  YUV 4:2:2 planar 16, LE.");
    printf("  yuv444p16le             ""Suitable for higher-quality encoding.  YUV 4:4:4 planar, 48bpp, LE.");
}

/**
 * Parses format string and gets two parameters.
 *
 * @param formatStr format string
 * @param pattern pattern string to find
 * @param delimiter parameters delimiter
 * @param firstPar first parameter to set
 * @param secondPar second parameter to set
 */
static void getTwoParameters(const char *formatStr, const char *pattern, char delimiter, int *firstPar, int *secondPar)
{
    int  f = 0;
    int  s = 0;
    char tmp[256] = { 0 };
    char *delim;
    char *comma;
    long fs;
    long ss;
    char *format = strstr(formatStr, pattern);

    if (format == NULL)
        return;

    format += strlen(pattern);
    delim = strchr(format, delimiter);
    fs    = delim - format;

    if (delim == NULL || fs == 0 || fs > 255)
        return;

    memcpy(tmp, format, fs);
    f = atoi(tmp);
    if (f <= 0)
        return;

    format += fs + 1;
    comma = strchr(format, ',');
    ss = (comma) ? comma - format : strlen(format);
    if (ss == 0 || ss > 255)
        return;

    memset(tmp, 0, sizeof(tmp));
    memcpy(tmp, format, ss);
    s = atoi(tmp);
    if (s == 0)
        return;

    *firstPar  = f;
    *secondPar = s;
}

/**
 * Gets interlace parameter.
 *
 * @param formatStr format string
 * @param interlace interlace parameter to set
 */
static void getInterlacing(const char *formatStr, BOOL *interlace)
{
    if (strstr(formatStr, FORMAT_INTERLACE_STR))
        *interlace = YES;
}

/**
 * Gets pixel format parameter.
 *
 * @param formatStr format string
 * @param pxlFmt pixel format parameter to set
 */
static void getPixelFormat(const char *formatStr, NSString **pxlFmt)
{
    if (formatStr == NULL)
        return;
    *pxlFmt = [NSString stringWithUTF8String:formatStr];
}

/**
 * Parses format option value.
 *
 * @param formatStr format option value
 * @param width frame width to set
 * @param height frame height to set
 * @param tsNum timescale numerator to set
 * @param tsDen timescale denumerator to set
 * @param darNum display aspect ratio numerator to set
 * @param darDen display aspect ratio denumerator to set
 * @param interlace interlace flag to set
 */
static void parseFormat(const char *formatStr,
                        int *width,
                        int *height,
                        int *tsNum,
                        int *tsDen,
                        int *darNum,
                        int *darDen,
                        BOOL *interlace)
{
    getTwoParameters(formatStr, FORMAT_SCALE_STR, ':', width, height);
    getTwoParameters(formatStr, FORMAT_FPS_STR, '/', tsDen, tsNum);
    getTwoParameters(formatStr, FORMAT_DAR_STR, '/', darNum, darDen);
    getInterlacing(formatStr, interlace);
}

/**
 * Reads raw image data from input file.
 *
 * @param in intput file or stdin
 * @param rawimg raw image data pointer
 * @param rawimgSize raw image data size to read
 *
 * @return 0 on success, -1 on end of file and -2 on file errors
 */
static int readRawimage(FILE *in, uint8_t *rawimg, uint64_t rawimgSize)
{
    uint8_t *p = rawimg;
    uint64_t size = rawimgSize;
    size_t readNumber = 0;

    if (feof(in))
        return -1;

    do
    {
        readNumber = fread(p, 1, size, in);
        if (ferror(in))
            return -2;

        p += readNumber;
        size -= readNumber;
    }
    while (feof(in) == 0 && size);

    return 0;
}

/**
 * Converts planar YUV 4:2:2 16-bit to packed format.
 *
 * @param planar planar data pointer
 * @param width frame width
 * @param height frame height
 * @param packed converted output data pointer
 */
static void pack422YpCbCr16PlanarTo422YpCbCr16(uint8_t *planar, int width, int height, uint8_t *packed)
{
    int rowSize = width * 2;
    uint16_t *Y  = (uint16_t *)planar;
    uint16_t *Cb = (uint16_t *)(planar + height * width * 2);
    uint16_t *Cr = (uint16_t *)(planar + height * width * 3);
    uint16_t *p = (uint16_t *)packed;

    for (int r = 0; r < height; r++)
    {
        for (int cn = 0; cn < rowSize; cn += 4)
        {
            *p++ = *Cb++; // Cb0
            *p++ = *Y++;  // Y0
            *p++ = *Cr++; // Cr0
            *p++ = *Y++;  // Y1
        }

    }
}

/**
 * Converts planar YUV 4:4:4 16-bit to packed format.
 *
 * @param planar planar data pointer
 * @param width frame width
 * @param height frame height
 * @param packed converted output data pointer
 */
static void pack444YpCbCrA16PlanarTo4444AYpCbCr16(uint8_t *planar, int width, int height, uint8_t *packed)
{
    size_t          planeSize = width * height * 16 / 8;
    uint16_t        *Y = (uint16_t *)planar;
    uint16_t        *Cb = (void*)planar + planeSize;
    uint16_t        *Cr = (void*)planar + (2 * planeSize);
    uint16_t        *A = (void*)planar + (3 * planeSize);
    
    uint16_t        *p = (uint16_t*)packed;
    
    for (int y=0; y<height; ++y)    {
        for (int x=0; x<width; ++x) {
            *p++ = *A++;
            *p++ = *Y++;
            *p++ = *Cb++;
            *p++ = *Cr++;
        }
    }
}

/**
 * Writes frames from encoder internal queue to file.
 *
 * @param encoder ProresEncoder instance
 * @param writer MovieWriter instance
 */
static void writeEncodedFrames(ProresEncoder *encoder, MovieWriter *writer)
{
    CMSampleBufferRef sampleBuffer = NULL;

    while ((sampleBuffer = [encoder nextEncodedFrame]))
    {
        if (![writer writeSampleBuffer:sampleBuffer])
        {
            fprintf(stderr, "Cannot write encoded frame (%p).\n", sampleBuffer);
            continue;
        }

        CFRelease(sampleBuffer);
    }
}

int main(int argc, char *argv[])
{
    FILE          *in  = stdin;
    char          *outFileName = NULL;
    uint8_t       *rawimg = { 0 };
    size_t        rawimgSize = 0;
    size_t        packimgSize = 0;
    int           width = 1920;
    int           height = 1080;
    int           tsNum = 1;
    int           tsDen = 30;
    int           darNum = 0;
    int           darDen = 0;
    BOOL          interlace = NO;
    BOOL          hwAccel = YES;
    int           opt;
    int           ret;
    ProresEncoder *encoder;
    MovieWriter   *movieWriter;
    BOOL          highQualityExport = NO;
    static struct option longopts[] = {
        { "input" , required_argument, NULL, 'i' },
        { "pix_fmt", required_argument, NULL, 'p' },
        { "format", required_argument, NULL, 'f' },
        { "help"  , no_argument      , NULL, 'h' },
        { "verify", no_argument      , NULL, 'v' },
        { "test", no_argument      , NULL, 't' },
        { NULL    , 0                , NULL, 0 }
    };
    NSString        *pxlfmt = nil;
    BOOL            verify = NO;
    BOOL            testPattern = NO;

    while ((opt = getopt_long(argc, argv, "i:p:f:hvt", longopts, NULL)) != -1)
    {
        switch (opt)
        {
            case 'i':
                in = fopen(optarg, "r");
                if (in == NULL)
                {
                    perror("Input file opening fails");
                    return EXIT_FAILURE;
                }
            break;
            
            case 'p':
                
                getPixelFormat(optarg, &pxlfmt);
                if (pxlfmt != nil)  {
                    if ([pxlfmt caseInsensitiveCompare:@"yuv422p16le"]==NSOrderedSame)  {
                        //  default value- do nothing, not high quality
                    }
                    else if ([pxlfmt caseInsensitiveCompare:@"yuva444p16le"]==NSOrderedSame)    {
                        highQualityExport = YES;
                    }
                    else    {
                        perror("Unrecognized pixel format");
                        return EXIT_FAILURE;
                    }
                }
                fprintf(stderr, "highQualityExport flag is %d\n",highQualityExport);
                //highQualityExport = YES;
            break;

            case 'f':
                parseFormat(optarg, &width, &height, &tsNum, &tsDen, &darNum, &darDen, &interlace);
                if (darNum)
                    printf("Video settings: %dx%d %d/%d %d/%d %s\n",
                        width, height, tsDen, tsNum, darNum, darDen, (interlace) ? "interlaced" : "progressive");
                else
                    printf("Video settings: %dx%d %d/%d %s\n",
                        width, height, tsDen, tsNum, (interlace) ? "interlaced" : "progressive");
            break;

            case 'h':
                printUsage(argv[0]);
                return EXIT_SUCCESS;
            break;
            
            case 'v':
                verify = YES;
                fprintf(stderr, "verify flag is %d\n",verify);
            break;
            
            case 't':
                testPattern = YES;
                fprintf(stderr, "test pattern is %d\n",testPattern);
            break;

            default:
                /* do nothing */ ;
        }
    }

    if (argc <= optind)
    {
        fprintf(stderr, "Ecpected output file name argument after options.\n");
        return EXIT_FAILURE;
    }

    outFileName = argv[optind];

    movieWriter = [[MovieWriter alloc] initWithOutFile:[NSString stringWithUTF8String:outFileName] timescale:tsDen];
    if (movieWriter == nil)
        return EXIT_FAILURE;

    encoder = [[ProresEncoder alloc] initWithWidth:width
                                            height:height
                                             tsNum:tsNum
                                             tsDen:tsDen
                                            darNum:darNum
                                            darDen:darDen
                                         interlace:interlace
                               enableHwAccelerated:hwAccel
                                   highQualityFlag:highQualityExport
                                      verifyOutput:verify];
    if (encoder == nil)
        return EXIT_FAILURE;
    
    if (highQualityExport)
    {
        rawimgSize = height * width * 64 / 8;   //  16 bits per channel * 4 channels / 8 bits per byte
        packimgSize = rawimgSize;
    }
    else
    {
        rawimgSize = height * width * 4; // 4:2:2 16bit -> (width * 2 + width + width) * height
        packimgSize = rawimgSize;
    }
    
    rawimg = malloc(rawimgSize);
    if (rawimg == NULL)
    {
        fprintf(stderr, "Memory for input data cannot be allocated.\n");
        return EXIT_FAILURE;
    }
    
    //  do i need to generate a buffer that holds a test pattern to be encoded?
    CVPixelBufferRef        testPatternRef = NULL;
    if (testPattern)
    {
        //  generate the buffer
        CVReturn        cvRet = kCVReturnSuccess;
        if (highQualityExport)
        {
            cvRet = CVPixelBufferCreate(
                kCFAllocatorDefault,
                width,
                height,
                kCVPixelFormatType_4444AYpCbCr16,
                NULL,
                &testPatternRef);
        }
        else
        {
            cvRet = CVPixelBufferCreate(
                kCFAllocatorDefault,
                width,
                height,
                kCVPixelFormatType_422YpCbCr16,
                NULL,
                &testPatternRef);
        }
        if (cvRet!=kCVReturnSuccess || testPatternRef==NULL)
        {
            fprintf(stderr, "ERR: %d, cannot generate pixel buffer in main()\n",cvRet);
            return EXIT_FAILURE;
        }
        
        /*  populate the buffer with a simple gradient.  remember, we're populating a 16-bit buffer in
        such a way that when it is converted to a 10-bit or 12-bit buffer, the luma value will increase 
        by 1 in the 10-bit (1/1024) or 12-bit space (1/4096)      */
        CVPixelBufferLockBaseAddress(testPatternRef, 0);
        void        *baseAddress = CVPixelBufferGetBaseAddress(testPatternRef);
        size_t      bytesPerRow = CVPixelBufferGetBytesPerRow(testPatternRef);
        if (highQualityExport)
        {
        	/*
        	uint16_t    lumaCount = 0;
            int         lumaValsPerCount = 16;  //  12-bit
            //int           lumaValsPerCount = 64;  //  10-bit
            for (int row=0; row<height; ++row)
            {
                for (int col=0; col<width; ++col)
                {
                    void        *dstPixel = baseAddress + (row*bytesPerRow) + (col * (16 * 4 / 8));
                    uint16_t    *dstA = (uint16_t*)dstPixel;
                    uint16_t    *dstY = dstA + 1;
                    uint16_t    *dstCb = dstY + 1;
                    uint16_t    *dstCr = dstCb + 1;
                    *dstA = 0xFFFF;
                    *dstY = lumaCount * lumaValsPerCount;
                    *dstCb = 0x7FFF;
                    *dstCr = 0x7FFF;
                    ++lumaCount;
                    if (lumaCount >= (0xFFFF / lumaValsPerCount))
                        lumaCount = 0;
                }
            }
            */
            
            int			maxLumaCount = 4095;	//	12-bit
            //int			maxLumaCount = 1023;	//	10-bit
            int			numRows = (int)ceil((double)maxLumaCount/(double)width);
            int			pixelsPerRow = height/numRows;
            int			pixelsPerRowCount = 0;
            int			gradientRowIndex = 0;
            
            //uint16_t    lumaCount = 0;
            int         lumaValsPerCount = 16;  //  12-bit
            //int           lumaValsPerCount = 64;  //  10-bit
            for (int row=0; row<height; ++row)
            {
                for (int col=0; col<width; ++col)
                {
                    void        *dstPixel = baseAddress + (row*bytesPerRow) + (col * (16 * 4 / 8));	//	12-bit 444
                    //void        *dstPixel = baseAddress + (row*bytesPerRow) + (col * (16 * 2 / 8));	//	10-bit 422
                    uint16_t    *dstA = (uint16_t*)dstPixel;
                    uint16_t    *dstY = dstA + 1;
                    uint16_t    *dstCb = dstY + 1;
                    uint16_t    *dstCr = dstCb + 1;
                    
                    *dstA = 0xFFFF;
                    //*dstY = lumaCount * lumaValsPerCount;
                    *dstY = lumaValsPerCount * (col + (width * gradientRowIndex));
                    *dstCb = 0x7FFF;
                    *dstCr = 0x7FFF;
                    //++lumaCount;
                    //if (lumaCount >= (0xFFFF / lumaValsPerCount))
                    //    lumaCount = 0;
                }
                
                ++pixelsPerRowCount;
                if (pixelsPerRowCount >= pixelsPerRow)	{
                	pixelsPerRowCount = 0;
                	++gradientRowIndex;
                }
            }
        }
        else
        {
        	/*
        	uint16_t    lumaCount = 0;
            //int           lumaValsPerCount = 16;  //  12-bit
            int         lumaValsPerCount = 64;  //  10-bit
            for (int row=0; row<height; ++row)
            {
                for (int col=0; col<width; ++col)
                {
                    void        *dstPixel = baseAddress + (row*bytesPerRow) + (col * (16 * 2 / 8));
                    uint16_t    *dstColor = (uint16_t*)dstPixel;
                    uint16_t    *dstY = dstColor + 1;
                    *dstColor = 0x7FFF;
                    *dstY = lumaCount * lumaValsPerCount;
                    ++lumaCount;
                    if (lumaCount >= (0xFFFF / lumaValsPerCount))
                        lumaCount = 0;
                }
            }
            */
            //int			maxLumaCount = 4095;	//	12-bit
            int			maxLumaCount = 1023;	//	10-bit
            int			numRows = (int)ceil((double)maxLumaCount/(double)width);
            int			pixelsPerRow = height/numRows;
            int			pixelsPerRowCount = 0;
            int			gradientRowIndex = 0;
            
            //uint16_t    lumaCount = 0;
            //int         lumaValsPerCount = 16;  //  12-bit
            int           lumaValsPerCount = 64;  //  10-bit
            for (int row=0; row<height; ++row)
            {
                for (int col=0; col<width; ++col)
                {
                    //void        *dstPixel = baseAddress + (row*bytesPerRow) + (col * (16 * 4 / 8));	//	12-bit 444
                    void        *dstPixel = baseAddress + (row*bytesPerRow) + (col * (16 * 2 / 8));	//	10-bit 422
                    uint16_t    *dstColor = (uint16_t*)dstPixel;
                    uint16_t    *dstY = dstColor + 1;
                    
                    *dstColor = 0x7FFF;
                    //*dstY = lumaCount * lumaValsPerCount;
                    *dstY = lumaValsPerCount * (col + (width * gradientRowIndex));
                    //++lumaCount;
                    //if (lumaCount >= (0xFFFF / lumaValsPerCount))
                    //    lumaCount = 0;
                }
                
                ++pixelsPerRowCount;
                if (pixelsPerRowCount >= pixelsPerRow)	{
                	pixelsPerRowCount = 0;
                	++gradientRowIndex;
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(testPatternRef, 0);
    }
    
    printf("Encoding started to file %s\n", outFileName);

    while ((ret = readRawimage(in, rawimg, rawimgSize)) == 0)
    {
        // packedImg should not be released manually and will be managed by encoder
        uint8_t *packedImg = malloc(packimgSize);
        if (packedImg == NULL)
        {
            fprintf(stderr, "Memory for packed image cannot be allocated.\n");
            return EXIT_FAILURE;
        }

        memset(packedImg, 0, packimgSize);
        
        if (highQualityExport) 
        {
            pack444YpCbCrA16PlanarTo4444AYpCbCr16(rawimg, width, height, packedImg);
            //memcpy(packedImg, rawimg, rawimgSize);
        }
        else
        {
            pack422YpCbCr16PlanarTo422YpCbCr16(rawimg, width, height, packedImg);
        }
        
        if (testPatternRef != NULL)
        {
            if (![encoder encodePixelBufferRef:testPatternRef])
            {
                fprintf(stderr, "Cannot encode test image. Skip this portion of data (%p).\n", packedImg);
                continue;
            }
        }
        else
        {
            if (![encoder encodeWithRawImage:packedImg])
            {
                fprintf(stderr, "Cannot encode raw image. Skip this portion of data (%p).\n", packedImg);
                continue;
            }
        }

        writeEncodedFrames(encoder, movieWriter);
    }

    // flush all encoded frames from internal queue
    if (![encoder flushFrames])
        fprintf(stderr, "Cannot flush encoded frames.\n");

    // write all frames after flush encoder
    writeEncodedFrames(encoder, movieWriter);

    // write movie file format metadata
    [movieWriter finishWriting];

    printf("Encoding finished.\n");

    free(rawimg);
    fclose(in);
    
    if (testPatternRef != NULL)
    {
        CFRelease(testPatternRef);
    }

    return (ret <= -2) ? EXIT_FAILURE : EXIT_SUCCESS;
}
