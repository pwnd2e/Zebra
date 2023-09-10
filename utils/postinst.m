#import <Foundation/Foundation.h>
#import <sys/stat.h>

int main(void) {
	// Ensure supersling permissions if we need it on this iOS version.
	if (@available(iOS 13, *)) {
	} else {
		if (lchown(INSTALL_PREFIX "/Applications/Zebra.app/supersling", 0, 0) != 0 || lchmod(INSTALL_PREFIX "/Applications/Zebra.app/supersling", 06755) != 0) {
			errno_t error = errno;
			NSLog(@"Failed to set permissions on supersling: %s", strerror(error));
			return 1;
		}
	}

	// On iOS before 11, we own the sileo:// URL scheme to support payment providers without the use
	// of SFAuthenticationSession, which was added in iOS 11. Modify our own Info.plist to do that.
	// This is fair game to do because Sileo only ever supported iOS 11.0+.
	if (@available(iOS 11, *)) {
	} else {
		NSMutableDictionary *infoPlist = [NSMutableDictionary dictionaryWithContentsOfFile:@"/Applications/Zebra.app/Info.plist"];
		NSMutableArray *urlTypes = [infoPlist[@"CFBundleURLTypes"] mutableCopy];
		NSMutableDictionary *urlType = [urlTypes[0] mutableCopy];
		NSMutableArray *urlSchemes = [urlType[@"CFBundleURLSchemes"] mutableCopy];
		[urlSchemes addObject:@"sileo"];
		urlType[@"CFBundleURLSchemes"] = urlSchemes;
		urlTypes[0] = urlType;
		infoPlist[@"CFBundleURLTypes"] = urlTypes;

		if (![infoPlist writeToFile:@"/Applications/Zebra.app/Info.plist" atomically:YES]) {
			NSLog(@"Failed to configure payment providers URL scheme");
			return 1;
		}
	}

	return 0;
}
