#import <coinbase-official/CoinbaseOAuth.h>

#import "BTCoinbase.h"
#import "BTClient_Internal.h"
#import "BTAppSwitchErrors.h"

@interface BTCoinbase ()
@property (nonatomic, strong) BTClient *client;
@property (nonatomic, assign) CoinbaseOAuthAuthenticationMechanism authenticationMechanism;
@end

@implementation BTCoinbase

@synthesize returnURLScheme = _returnURLScheme;
@synthesize delegate = _delegate;

+ (instancetype)sharedCoinbase {
    static BTCoinbase *coinbase;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        coinbase = [[self alloc] init];
    });
    return coinbase;
}

- (BOOL)providerAppSwitchAvailableForClient:(BTClient *)client {
    return self.returnURLScheme && [self appSwitchAvailableForClient:client] && [CoinbaseOAuth isAppOAuthAuthenticationAvailable];
}

#pragma mark Helpers

- (NSURL *)redirectUri {
    NSURLComponents *components = [[NSURLComponents alloc] init];
    components.scheme = [self returnURLScheme];
    components.path = @"/vzero/auth/coinbase/redirect";
    components.host = @"x-callback-url";
    return [components URL];
}

- (NSError *)errorWithCode:(BTAppSwitchErrorCode)code localizedDescription:(NSString *)localizedDescription {
    NSDictionary *userInfo;
    if (localizedDescription) {
        userInfo = @{NSLocalizedDescriptionKey: localizedDescription };
    }
    return [NSError errorWithDomain:BTAppSwitchErrorDomain code:code userInfo:userInfo];
}


#pragma mark BTAppSwitching

- (BOOL)appSwitchAvailableForClient:(BTClient *)client {
    return client.configuration.coinbaseEnabled;
}

// In this context, "AppSwitch" includes both browser switch and provider app switch
- (BOOL)initiateAppSwitchWithClient:(BTClient *)client delegate:(id<BTAppSwitchingDelegate>)delegate error:(NSError *__autoreleasing *)error {

    self.client = client;
    self.delegate = delegate;

    [self.client postAnalyticsEvent:@"ios.coinbase.initiate.started"];

    if (!self.returnURLScheme) {
        [self postAnalyticsEventWithName:@"initiate" status:@"invalid-return-url-scheme"];
        if (error != NULL) {
            *error = [self errorWithCode:BTAppSwitchErrorIntegrationReturnURLScheme localizedDescription:@"Coinbase is not available due to invalid return URL scheme"];
        }
        return NO;
    }

    if (![self appSwitchAvailableForClient:client]) {
        [self postAnalyticsEventWithName:@"initiate" status:@"unavailable"]; // postAnalyticsEvent:@"ios.coinbase.initiate.unavailable"
        if (error != NULL) {
            *error = [self errorWithCode:BTAppSwitchErrorDisabled localizedDescription:@"Coinbase is not available due to Configuration"];
        }
        return NO;
    }

    self.authenticationMechanism = [CoinbaseOAuth startOAuthAuthenticationWithClientId:client.configuration.coinbaseClientId
                                                                                 scope:client.configuration.coinbaseScope
                                                                           redirectUri:[self.redirectUri absoluteString]
                                                                                  meta:(client.configuration.coinbaseMerchantAccount ? @{ @"authorizations_merchant_account": client.configuration.coinbaseMerchantAccount } : nil)];

    switch (self.authenticationMechanism) {
        case CoinbaseOAuthMechanismNone:
            [self postAnalyticsEventWithName:@"initiate" status:@"failed"]; // postAnalyticsEvent:@"ios.coinbase.initiate.failed"
            if (error != NULL) {
                *error = [self errorWithCode:BTAppSwitchErrorFailed localizedDescription:@"Coinbase is not available"];
            }
            break;
        case CoinbaseOAuthMechanismApp:
            [self postAnalyticsEventWithName:@"appswitch" status:@"started"]; // postAnalyticsEvent:@"ios.coinbase.appswitch.started"
            break;
        case CoinbaseOAuthMechanismBrowser:
            [self postAnalyticsEventWithName:@"webswitch" status:@"started"]; // postAnalyticsEvent:@"ios.coinbase.webswitch.started"
            break;
    }

    return self.authenticationMechanism != CoinbaseOAuthMechanismNone;
}

- (BOOL)canHandleReturnURL:(NSURL *)url sourceApplication:(__unused NSString *)sourceApplication {
    NSURL *redirectURL = self.redirectUri;
    BOOL schemeMatches = [[url.scheme lowercaseString] isEqualToString:[redirectURL.scheme lowercaseString]];
    BOOL hostMatches = [url.host isEqualToString:redirectURL.host];
    BOOL pathMatches = [url.path isEqualToString:redirectURL.path];
    return schemeMatches && hostMatches && pathMatches;
}

- (void)handleReturnURL:(NSURL *)url {
    if (![self canHandleReturnURL:url sourceApplication:nil]) {
        return;
    }

    [CoinbaseOAuth finishOAuthAuthenticationForUrl:url
                                          clientId:self.client.configuration.coinbaseClientId
                                      clientSecret:nil
                                        completion:^(id response, NSError *error)
     {
         if (error) {
             if ([error.domain isEqualToString:CoinbaseErrorDomain] && error.code == CoinbaseOAuthError && [error.userInfo[CoinbaseOAuthErrorUserInfoKey] isEqual:@"access_denied"]) {
                 // postAnalyticsEvent:@"ios.coinbase.appswitch.denied", postAnalyticsEvent:@"ios.coinbase.webswitch.denied"
                 [self postAnalyticsEventForAuthenticationMechanism:self.authenticationMechanism status:@"denied"];
             } else {
                 // postAnalyticsEvent:@"ios.coinbase.appswitch.failed", postAnalyticsEvent:@"ios.coinbase.webswitch.failed"
                 [self postAnalyticsEventForAuthenticationMechanism:self.authenticationMechanism status:@"failed"];
             }
             [self informDelegateDidFailWithError:error];
         } else {
             // postAnalyticsEvent:@"ios.coinbase.appswitch.authorized", postAnalyticsEvent:@"ios.coinbase.webswitch.authorized"
             [self postAnalyticsEventForAuthenticationMechanism:self.authenticationMechanism status:@"authorized"];
             [self.client saveCoinbaseAccount:response
                                      success:^(BTCoinbasePaymentMethod *coinbasePaymentMethod)
              {
                  // postAnalyticsEvent:@"ios.coinbase.tokenize.succeeded"
                  [self postAnalyticsEventWithName:@"tokenize" status:@"succeeded"];
                  [self informDelegateDidCreatePaymentMethod:coinbasePaymentMethod];
              } failure:^(NSError *error) {
                  // Should not be posted if Coinbase fails to authorize, i.e. (web|app)switch.denied or (web|app)switch.failed
                  // postAnalyticsEvent:@"ios.coinbase.tokenize.failed"
                  [self postAnalyticsEventWithName:@"tokenize" status:@"failed"];
                  [self informDelegateDidFailWithError:error];
              }];
         }
     }];
}


#pragma mark Delegate Informers

- (void)informDelegateDidFailWithError:(NSError *)error {
    if ([self.delegate respondsToSelector:@selector(appSwitcher:didFailWithError:)]) {
        [self.delegate appSwitcher:self didFailWithError:error];
    }
}

- (void)informDelegateDidCreatePaymentMethod:(BTCoinbasePaymentMethod *)paymentMethod {
    if ([self.delegate respondsToSelector:@selector(appSwitcher:didCreatePaymentMethod:)]) {
        [self.delegate appSwitcher:self didCreatePaymentMethod:paymentMethod];
    }
}


#pragma mark Analytics Helpers

- (void)postAnalyticsEventWithName:(NSString *)name status:(NSString *)status {
    NSString *eventName = [NSString stringWithFormat:@"ios.coinbase.%@.%@", name, status];
    [self.client postAnalyticsEvent:eventName];
}

- (void)postAnalyticsEventForAuthenticationMechanism:(CoinbaseOAuthAuthenticationMechanism)mechanism status:(NSString *)status {
    NSString *name;
    switch (mechanism) {
        case CoinbaseOAuthMechanismNone: name = @"unknown"; break; // postAnalyticsEvent:@"ios.coinbase.unknown.authorized" should not happen during normal use
        case CoinbaseOAuthMechanismBrowser: name = @"webswitch"; break;
        case CoinbaseOAuthMechanismApp: name = @"appswitch"; break;
    }
    
    NSString *eventName = [NSString stringWithFormat:@"ios.coinbase.%@.%@", name, status];
    [self.client postAnalyticsEvent:eventName];
}

@end