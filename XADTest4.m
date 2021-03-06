/*
 * XADTest4.m
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
#import "XADArchiveParser.h"
#import "XADTestUtilities.h"

@interface ArchiveTester:NSObject
{
	int indent;
	int successcount,unknowncount,dircount,linkcount;
}
@end

@implementation ArchiveTester

-(id)initWithIndentLevel:(int)indentlevel
{
	if((self=[super init]))
	{
		indent=indentlevel;
		successcount=unknowncount=dircount=linkcount=0;
	}
	return self;
}

-(void)done:(XADArchiveParser *)parser
{
	for(int i=0;i<indent;i++) printf(" ");
	printf("%s (%s): %d successful files, %d unknown files, %d directories, %d links\n",
	[[parser name] UTF8String],[[parser formatName] UTF8String],successcount,unknowncount,dircount,linkcount);
}

-(void)archiveParser:(XADArchiveParser *)parser foundEntryWithDictionary:(NSDictionary *)dict
{
	NSNumber *dir=[dict objectForKey:XADIsDirectoryKey];
	NSNumber *link=[dict objectForKey:XADIsLinkKey];
	CSHandle *fh=nil;

	if(dir&&[dir boolValue]) { dircount++; }
	else if(link&&[link boolValue]) { linkcount++; }
	else
	{
		fh=[parser handleForEntryWithDictionary:dict wantChecksum:YES];

		if(!fh)
		{
			NSLog(@"Could not obtain handle for entry: %@",dict);
			exit(1);
		}
		else if([fh hasChecksum])
		{
			[fh seekToEndOfFile];
			if([fh isChecksumCorrect]) successcount++;
			else
			{
				NSLog(@"Checksum failure for entry: %@",dict);
				exit(1);
			}
		}
		else unknowncount++;
	}

	NSNumber *arch=[dict objectForKey:XADIsArchiveKey];
	if(arch&&[arch boolValue])
	{
		[fh seekToFileOffset:0];

		XADArchiveParser *parser=[XADArchiveParser archiveParserForHandle:fh name:[[dict objectForKey:XADFileNameKey] string]];
		ArchiveTester *tester=[[[ArchiveTester alloc] initWithIndentLevel:indent+2] autorelease];
		[parser setDelegate:tester];
		[parser parse];
		[tester done:parser];
	}
}

-(BOOL)archiveParsingShouldStop:(XADArchiveParser *)parser
{
	return NO;
}

@end

int main(int argc,char **argv)
{
	NSString *filename;
	NSEnumerator *enumerator=[FilesForArgs(argc,argv) objectEnumerator];
	while(filename=[enumerator nextObject])
	{
		NSAutoreleasePool *pool=[[NSAutoreleasePool alloc] init];

		printf("Testing %s...\n",[filename UTF8String]);

		NSString *filename=[NSString stringWithUTF8String:argv[i]];
		XADArchiveParser *parser=[XADArchiveParser archiveParserForPath:filename];
		ArchiveTester *tester=[[[ArchiveTester alloc] initWithIndentLevel:2] autorelease];
		[parser setDelegate:tester];

		NSString *pass=FigureOutPassword(filename);
		if(pass) [parser setPassword:pass];

		[parser parse];
		[tester done:parser];

		[pool release];
	}
	return 0;
}
