/*
 * XADWARCParser.m
 *
 * Copyright (c) 2017-present, MacPaw Inc. All rights reserved.
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this library; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston,
 * MA 02110-1301  USA
 */
#import "XADWARCParser.h"
#import "Scanning.h"

#import "XADGzipParser.h"
#import "XADDeflateHandle.h"
#import "CSBzip2Handle.h"
#import "XADCompressHandle.h"

@implementation XADWARCParser

+(int)requiredHeaderSize { return 10; }

+(BOOL)recognizeFileWithHandle:(CSHandle *)handle firstBytes:(NSData *)data name:(NSString *)name
{
	const uint8_t *bytes=[data bytes];
	int length=[data length];

	if(length<10) return NO;
	return memcmp(bytes,"WARC/1.0\r\n",10)==0;
}

-(void)parse
{
	CSHandle *fh=[self handle];

	NSMutableArray *recordarray=[NSMutableArray array];
	NSMutableDictionary *records=[NSMutableDictionary dictionary];

	// Read all WARC records into memory, along with the HTTP headers
	// for application/http records.

	NSMutableDictionary *lastrecord=nil;
	while(![fh atEndOfFile])
	{
		NSAutoreleasePool *pool=[NSAutoreleasePool new];

		NSString *marker=[fh readLineWithEncoding:NSUTF8StringEncoding];
		if(![marker isEqual:@"WARC/1.0"])
		{
			// The Content-Length record was wrong, so attempt to find the next
			// record and correct the previously recorded record.
			BOOL found=[fh scanForByteString:(const uint8_t *)"\r\n\r\nWARC/1.0\r\n" length:14];

			off_t realendofrecord=[fh offsetInFile];
			[lastrecord setObject:[NSNumber numberWithLongLong:realendofrecord] forKey:@"EndOfRecord"];

			if(!found) break;

			[fh skipBytes:14];
		}

		NSMutableDictionary *record=[self parseHTTPHeadersWithHandle:fh];
		lastrecord=record;

		off_t contentstart=[fh offsetInFile];

		NSString *recordid=[record objectForKey:@"WARC-Record-ID"];
		NSString *contentlength=[record objectForKey:@"Content-Length"];
		NSString *contenttype=[record objectForKey:@"Content-Type"];

		if(!contentlength) [XADException raiseIllegalDataException];
		NSScanner *scanner=[NSScanner scannerWithString:contentlength];
		long long length=0;
		[scanner scanLongLong:&length];

		off_t endofrecord=contentstart+length;

		[record setObject:[NSNumber numberWithLongLong:contentstart] forKey:@"ContentStart"];
		[record setObject:[NSNumber numberWithLongLong:endofrecord] forKey:@"EndOfRecord"];

		if([contenttype hasPrefix:@"application/http"])
		{
			NSArray *headers=[self readHTTPHeadersWithHandle:fh];
			off_t bodystart=[fh offsetInFile];

			[record setObject:headers forKey:@"HTTPHeaders"];
			[record setObject:[NSNumber numberWithLongLong:bodystart] forKey:@"HTTPBodyStart"];
		}

		[recordarray addObject:record];
		[records setObject:record forKey:recordid];

		[fh seekToFileOffset:endofrecord+4];

		[pool release];
	}

	// Find all response records with 200 status, and build a
	// directory tree of the file names.

	NSMutableArray *filerecords=[NSMutableArray array];
	NSMutableDictionary *root=[NSMutableDictionary dictionary];

	NSEnumerator *enumerator=[recordarray objectEnumerator];
	NSMutableDictionary *record;
	while((record=[enumerator nextObject]))
	{
		NSString *type=[record objectForKey:@"WARC-Type"];
		NSArray *headers=[record objectForKey:@"HTTPHeaders"];
		NSString *status=[headers objectAtIndex:0];

		if([type isEqual:@"response"])
		if([status matchedByPattern:@"^HTTP/[0-9]+\\.[0-9]+ 200"])
		{
			NSString *target=[record objectForKey:@"WARC-Target-URI"];

			NSArray *components=[self pathComponentsForURLString:target];
			if(components)
			{
				NSMutableDictionary *dir=root;

				NSUInteger count=[components count];
				for(NSUInteger i=0;i<count-1;i++)
				{
					NSString *component=[components objectAtIndex:i];
					dir=[self insertDirectory:component inDirectory:dir];
				}

				[self insertFile:[components lastObject] record:record inDirectory:dir];

				[filerecords addObject:record];
			}
			else NSLog(@"Failed to parse URL \"%@\"",target);
		}
	}

	// Walk the finished directory tree to generate XADPaths for all files.
	[self buildXADPathsForFilesInDirectory:root parentPath:[self XADPath]];

	// Iterate over the files, finding and loading the request
	// records and emit archive entries. 

	enumerator=[filerecords objectEnumerator];
	while((record=[enumerator nextObject]))
	{
		NSString *target=[record objectForKey:@"WARC-Target-URI"];
		NSNumber *startnum=[record objectForKey:@"HTTPBodyStart"];
		NSNumber *endnum=[record objectForKey:@"EndOfRecord"];
		NSArray *responseheaders=[record objectForKey:@"HTTPHeaders"];
		XADPath *path=[record objectForKey:@"XADPath"];

		NSNumber *lengthnum=[NSNumber numberWithLongLong:[endnum longLongValue]-[startnum longLongValue]];

		NSMutableDictionary *dict=[NSMutableDictionary dictionaryWithObjectsAndKeys:
			path,XADFileNameKey,
			lengthnum,XADFileSizeKey,
			lengthnum,XADCompressedSizeKey,
			startnum,XADDataOffsetKey,
			lengthnum,XADDataLengthKey,
			target,@"WARCTargetURI",
			responseheaders,@"WARCResponseHeaders",
		nil];

		NSString *requestid=[record objectForKey:@"WARC-Concurrent-To"];
		NSDictionary *request=[records objectForKey:requestid];
		if(request)
		{
			NSArray *requestheaders=[request objectForKey:@"HTTPHeaders"];
			[dict setObject:requestheaders forKey:@"WARCRequestHeaders"];

			NSNumber *requeststartnum=[request objectForKey:@"HTTPBodyStart"];
			NSNumber *requestlengthnum=[request objectForKey:@"HTTPBodyLength"];
			off_t start=[requeststartnum longLongValue];
			off_t length=[requestlengthnum longLongValue];

			if(length)
			{
				[fh seekToFileOffset:start];
				NSData *requestbody=[fh readDataOfLength:(int)length];

				[dict setObject:requestbody forKey:@"WARCRequestBody"];
			}
		}

		[self addEntryWithDictionary:dict];
	}

	// TODO: Handle more record types, and store their contents as file and archive
	// metadata. Patches welcome!

}




-(NSMutableDictionary *)parseHTTPHeadersWithHandle:(CSHandle *)handle
{
	NSMutableDictionary *headers=[NSMutableDictionary dictionary];
	for(;;)
	{
		NSString *line=[handle readLineWithEncoding:NSUTF8StringEncoding];
		if([line length]==0) return headers;

		NSArray *matches=[line substringsCapturedByPattern:@"^([^:]+):[ \t]+(.*)$"];
		if(matches)
		{
			NSString *key=[matches objectAtIndex:1];
			NSString *value=[matches objectAtIndex:2];

			[headers setObject:value forKey:key];
		}
	}
}

-(NSArray *)readHTTPHeadersWithHandle:(CSHandle *)handle
{
	NSMutableArray *headers=[NSMutableArray array];
	for(;;)
	{
		NSString *line=[handle readLineWithEncoding:NSUTF8StringEncoding];
		if([line length]==0) return headers;
		[headers addObject:line];
	}
}




-(NSArray *)pathComponentsForURLString:(NSString *)urlstring
{
	NSArray *matches=[urlstring substringsCapturedByPattern:@"^https?://([^/]+)(/.*|())$"];
	if(!matches) return nil;
	NSString *host=[matches objectAtIndex:1];
	NSString *path=[matches objectAtIndex:2];

	if([path length]==0) return [NSArray arrayWithObject:host];

	NSMutableArray *components=[[[path pathComponents] mutableCopy] autorelease];
	[components replaceObjectAtIndex:0 withObject:host];

	if([[components lastObject] isEqual:@"/"]) [components removeLastObject];

	// TODO: Better processing of the path, handling escapes and such.

	return components;
}

-(NSMutableDictionary *)insertDirectory:(NSString *)name inDirectory:(NSMutableDictionary *)dir
{
	NSMutableDictionary *entry=[dir objectForKey:name];

	if(!entry)
	{
		// No such entry exists, so insert a new directory.
		NSMutableDictionary *newdir=[NSMutableDictionary dictionary];
		[dir setObject:newdir forKey:name];
		return newdir;
	}
	else if([entry objectForKey:@"/"])
	{
		// A file with the same name exists. Remove the file, insert a new directory,
		// then insert the file in the new directory as "index.html".
		[[entry retain] autorelease];
		[dir removeObjectForKey:name];

		NSMutableDictionary *newdir=[NSMutableDictionary dictionary];
		[dir setObject:newdir forKey:name];

		[self insertFile:@"index.html" record:entry inDirectory:newdir];

		return newdir;
	}
	else
	{
		// This directory already exists. No need to do anything, just return it.
		return entry;
	}
}

-(void)insertFile:(NSString *)name record:(NSMutableDictionary *)record inDirectory:(NSMutableDictionary *)dir
{
	[record setObject:[NSNull null] forKey:@"/"]; // Mark the record as a file.

	NSMutableDictionary *entry=[dir objectForKey:name];

	if(!entry)
	{
		// No such entry exists, so insert the file.
		[dir setObject:record forKey:name];
	}
	else if([entry objectForKey:@"/"])
	{
		// A file with the same name already exists. Find an unused name to use instead.
		NSString *newname;
		int counter=1;
		do { newname=[NSString stringWithFormat:@"%@.%d",name,counter++]; }
		while([dir objectForKey:newname]);

		[dir setObject:record forKey:newname];
	}
	else
	{
		// A directory with the same name exists. Attempt to insert the file
		// as "index.html" in that directory instead.
		[self insertFile:@"index.html" record:record inDirectory:entry];
	}
}

-(void)buildXADPathsForFilesInDirectory:(NSMutableDictionary *)dir parentPath:(XADPath *)parent
{
	NSEnumerator *enumerator=[dir keyEnumerator];
	NSString *name;
	while((name=[enumerator nextObject]))
	{
		NSMutableDictionary *entry=[dir objectForKey:name];
		XADString *xadname=[self XADStringWithString:name];
		XADPath *path=[parent pathByAppendingXADStringComponent:xadname];

		if([entry objectForKey:@"/"])
		{
			[entry setObject:path forKey:@"XADPath"];
		}
		else
		{
			[self buildXADPathsForFilesInDirectory:entry parentPath:path];
		}
	}
}

-(NSArray *)getContentEncodings:(NSArray *)headers
{
	NSError *err=nil;
	NSRegularExpression *re=[NSRegularExpression regularExpressionWithPattern:@"^content-encoding:[	 ]*" options:NSRegularExpressionCaseInsensitive error:&err];
	NSMutableArray *encodings=[NSMutableArray array];
	NSEnumerator *enumerator=[headers objectEnumerator];
	NSString *h;
	NSAssert1(err==nil, @"%@", err);
	while((h=[enumerator nextObject]))
	{
		NSTextCheckingResult *r=[re firstMatchInString:h options:0 range:NSMakeRange(0, h.length)];
		if(r==nil) continue;

		h = [h substringWithRange:NSMakeRange(r.range.length, h.length-r.range.length)];
		NSArray *hencodings=[h componentsSeparatedByString:@","];
		NSEnumerator *henumerator=[hencodings objectEnumerator];
		NSString *enc;
		while((enc=[henumerator nextObject]))
			[encodings addObject:[enc stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]];
	}

	return encodings;
}

-(CSHandle *)handleForEntryWithDictionary:(NSDictionary *)dict wantChecksum:(BOOL)checksum
{
	CSHandle *handle=[self handleAtDataOffsetForDictionary:dict];

	NSArray *encodings=[self getContentEncodings:[dict objectForKey:@"WARCResponseHeaders"]];
	NSEnumerator *enumerator=[encodings reverseObjectEnumerator];
	NSString *enc;
	while((enc=[enumerator nextObject]))
	{
		// https://www.iana.org/assignments/http-parameters/http-parameters.xhtml#content-coding
		// TODO: implement more encodings
		// FIXME: if the response is compressed, the size listed by unar/lsar is wrong
		//        since it refers to the size of the compressed response
		// compress is untested, I couldn't find a server to test it with.
		if([enc caseInsensitiveCompare:@"gzip"]==NSOrderedSame||
		[enc caseInsensitiveCompare:@"x-gzip"]==NSOrderedSame)
			handle=[[[XADGzipHandle alloc] initWithHandle:handle] autorelease];
		else if([enc caseInsensitiveCompare:@"deflate"]==NSOrderedSame)
			handle=[[[XADDeflateHandle alloc] initWithHandle:handle length:[handle fileSize]] autorelease];
		else if([enc caseInsensitiveCompare:@"identity"]==NSOrderedSame)
			; // No compression
		else if([enc caseInsensitiveCompare:@"bzip2"]==NSOrderedSame)
			handle=[[[CSBzip2Handle alloc] initWithHandle:handle length:[handle fileSize]] autorelease];
		else if([enc caseInsensitiveCompare:@"compress"]==NSOrderedSame||
		[enc caseInsensitiveCompare:@"x-compress"]==NSOrderedSame)
			handle=[[[XADCompressHandle alloc] initWithHandle:handle flags:0] autorelease];
		else
			NSLog(@"Unimplemented content-encoding: %@", enc);
	}

	return handle;
}

-(NSString *)formatName { return @"WARC"; }

@end
