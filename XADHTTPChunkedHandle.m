#include "XADHTTPChunkedHandle.h"

static inline int imin(int a,int b) { return a<b?a:b; }

@implementation XADHTTPChunkedHandle
// FIXME: XADUnarchiver returns XADDecrunchError because the sizes don't match, but the file itself is fine

-(id)initWithHandle:(CSHandle *)handle
{
	if((self=[super initWithInputBufferForHandle:handle]))
	{
		startoffs=[handle offsetInFile];
		chunkLeft=0;
		chunkLeftDigits=0;
	}
	return self;
}

-(void)resetStream
{
	[parent seekToFileOffset:startoffs];
	chunkLeft=0;
	chunkLeftDigits=0;
}

-(int)streamAtMost:(int)num toBuffer:(void *)outbuf
{
	uint8_t inbuf[4096];
	inbuf[4095]='\0';
	int totalread=0;
	int bufLeft=[parent readAtMost:imin(num, 4095) toBuffer:inbuf];
	while(bufLeft)
	{
		if(chunkLeft)
		{
			int nread = imin(bufLeft, chunkLeft);
			memcpy(outbuf, inbuf, nread);
			outbuf+=nread;
			chunkLeft-=nread;
			bufLeft-=nread;
			totalread+=nread;
			if(bufLeft)
				memmove(inbuf, inbuf+nread, bufLeft);
		}
		else
		{
			uint8_t *inbufread;
			errno=0;
			long long sizepart=strtoll(inbuf, &inbufread, 16);
			if(sizepart)
				assert(errno==0);
			else
				assert(errno==0||errno!=EINVAL);
			chunkLeft+=sizepart<<(4*chunkLeftDigits);
			chunkLeftDigits+=inbufread-inbuf;
			if(inbufread!=inbuf)
				while((inbufread)-inbuf<bufLeft) if((*inbufread++)=='\n')
				{
					chunkLeftDigits=0;
					break;
				}

			if(chunkLeft==0)
			{
				[self endStream];
				break;
			}

			bufLeft-=inbufread-inbuf;
			if(bufLeft)
				memmove(inbuf, inbufread, bufLeft);
		}
	}
	return totalread;
}

@end
