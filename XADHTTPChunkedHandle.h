#import "CSStreamHandle.h"

@interface XADHTTPChunkedHandle:CSStreamHandle
{
	off_t startoffs;
	long chunkLeft, chunkLeftDigits;
}

-(id)initWithHandle:(CSHandle *)handle;
-(void)resetStream;
-(int)streamAtMost:(int)num toBuffer:(void *)buffer;

@end
