#import "InAppUtils.h"
#import <StoreKit/StoreKit.h>
#import <React/RCTLog.h>
#import <React/RCTUtils.h>
#import "SKProduct+StringPrice.h"

@implementation InAppUtils
{
    NSArray *products;
    NSMutableDictionary *_callbacks;
    bool hasPurchaseCompletedListeners;
}

- (instancetype)init
{
    if ((self = [super init])) {
        _callbacks = [[NSMutableDictionary alloc] init];
        [[SKPaymentQueue defaultQueue] addTransactionObserver:self];
    }
    return self;
}

-(void)startObserving {
    hasPurchaseCompletedListeners = YES;
}

-(void)stopObserving {
    hasPurchaseCompletedListeners = NO;
}

- (dispatch_queue_t)methodQueue
{
    return dispatch_get_main_queue();
}

RCT_EXPORT_MODULE()

- (NSArray<NSString *> *)supportedEvents
{
    return @[@"purchaseCompleted"];
}

// Transactions initiated from App Store
- (BOOL)paymentQueue:(SKPaymentQueue *)queue
shouldAddStorePayment:(SKPayment *)payment
          forProduct:(SKProduct *)product {
    return hasPurchaseCompletedListeners;
}

- (void)paymentQueue:(SKPaymentQueue *)queue
 updatedTransactions:(NSArray *)transactions
{
    for (SKPaymentTransaction *transaction in transactions) {
        switch (transaction.transactionState) {
            case SKPaymentTransactionStateFailed: {
                NSString *key = RCTKeyForInstance(transaction.payment.productIdentifier);
                RCTResponseSenderBlock callback = _callbacks[key];
                if (callback) {
                    callback(@[RCTJSErrorFromNSError(transaction.error)]);
                    [_callbacks removeObjectForKey:key];
                } else {
                    RCTLogWarn(@"No callback registered for transaction with state failed.");
                }
                [[SKPaymentQueue defaultQueue] finishTransaction:transaction];
                break;
            }
            case SKPaymentTransactionStatePurchased: {
                NSString *key = RCTKeyForInstance(transaction.payment.productIdentifier);
                RCTResponseSenderBlock callback = _callbacks[key];
                NSDictionary *purchase = [self getPurchaseData:transaction];
                if (callback) {
                    callback(@[[NSNull null], purchase]);
                    [_callbacks removeObjectForKey:key];
                } else if (hasPurchaseCompletedListeners) {
                    [self sendEventWithName:@"purchaseCompleted" body:purchase];
                } else {
                    RCTLogWarn(@"No callback registered for transaction with state purchased.");
                }
                [[SKPaymentQueue defaultQueue] finishTransaction:transaction];
                break;
            }
            case SKPaymentTransactionStateRestored:
                [[SKPaymentQueue defaultQueue] finishTransaction:transaction];
                break;
            case SKPaymentTransactionStatePurchasing:
                NSLog(@"purchasing");
                break;
            case SKPaymentTransactionStateDeferred:
                NSLog(@"deferred");
                break;
            default:
                break;
        }
    }
}

RCT_EXPORT_METHOD(purchaseProductForUser:(NSString *)productIdentifier
                  username:(NSString *)username
                  callback:(RCTResponseSenderBlock)callback)
{
    [self doPurchaseProduct:productIdentifier username:username callback:callback];
}

RCT_EXPORT_METHOD(purchaseProduct:(NSString *)productIdentifier
                  callback:(RCTResponseSenderBlock)callback)
{
    [self doPurchaseProduct:productIdentifier username:nil callback:callback];
}

- (void) doPurchaseProduct:(NSString *)productIdentifier
                  username:(NSString *)username
                  callback:(RCTResponseSenderBlock)callback
{
    SKProduct *product;
    for(SKProduct *p in products)
    {
        if([productIdentifier isEqualToString:p.productIdentifier]) {
            product = p;
            break;
        }
    }

    if(product) {
        SKMutablePayment *payment = [SKMutablePayment paymentWithProduct:product];
        if(username) {
            payment.applicationUsername = username;
        }
        [[SKPaymentQueue defaultQueue] addPayment:payment];
        _callbacks[RCTKeyForInstance(payment.productIdentifier)] = callback;
    } else {
        callback(@[RCTMakeError(@"invalid_product", nil, nil)]);
    }
}

- (void)paymentQueue:(SKPaymentQueue *)queue
restoreCompletedTransactionsFailedWithError:(NSError *)error
{
    NSString *key = RCTKeyForInstance(@"restoreRequest");
    RCTResponseSenderBlock callback = _callbacks[key];
    if (callback) {
        switch (error.code)
        {
            case SKErrorPaymentCancelled:
                callback(@[RCTMakeError(@"user_cancelled", nil, nil)]);
                break;
            default:
                callback(@[RCTJSErrorFromNSError(error)]);
                break;
        }

        [_callbacks removeObjectForKey:key];
    } else {
        RCTLogWarn(@"No callback registered for restore product request.");
    }
}

- (void)paymentQueueRestoreCompletedTransactionsFinished:(SKPaymentQueue *)queue
{
    NSString *key = RCTKeyForInstance(@"restoreRequest");
    RCTResponseSenderBlock callback = _callbacks[key];
    if (callback) {
        NSMutableArray *productsArrayForJS = [NSMutableArray array];
        for(SKPaymentTransaction *transaction in queue.transactions){
            if(transaction.transactionState == SKPaymentTransactionStateRestored) {

                NSDictionary *purchase = [self getPurchaseData:transaction];

                [productsArrayForJS addObject:purchase];
                [[SKPaymentQueue defaultQueue] finishTransaction:transaction];
            }
        }
        callback(@[[NSNull null], productsArrayForJS]);
        [_callbacks removeObjectForKey:key];
    } else {
        RCTLogWarn(@"No callback registered for restore product request.");
    }
}

RCT_EXPORT_METHOD(restorePurchases:(RCTResponseSenderBlock)callback)
{
    NSString *restoreRequest = @"restoreRequest";
    _callbacks[RCTKeyForInstance(restoreRequest)] = callback;
    [[SKPaymentQueue defaultQueue] restoreCompletedTransactions];
}

RCT_EXPORT_METHOD(restorePurchasesForUser:(NSString *)username
                    callback:(RCTResponseSenderBlock)callback)
{
    NSString *restoreRequest = @"restoreRequest";
    _callbacks[RCTKeyForInstance(restoreRequest)] = callback;
    if(!username) {
        callback(@[RCTMakeError(@"username_required", nil, nil)]);
        return;
    }
    [[SKPaymentQueue defaultQueue] restoreCompletedTransactionsWithApplicationUsername:username];
}

RCT_EXPORT_METHOD(loadProducts:(NSArray *)productIdentifiers
                  callback:(RCTResponseSenderBlock)callback)
{
    SKProductsRequest *productsRequest = [[SKProductsRequest alloc]
                                          initWithProductIdentifiers:[NSSet setWithArray:productIdentifiers]];
    productsRequest.delegate = self;
    _callbacks[RCTKeyForInstance(productsRequest)] = callback;
    [productsRequest start];
}

RCT_EXPORT_METHOD(canMakePayments: (RCTResponseSenderBlock)callback)
{
    BOOL canMakePayments = [SKPaymentQueue canMakePayments];
    callback(@[[NSNull null], @(canMakePayments)]);
}

RCT_EXPORT_METHOD(receiptData:(RCTResponseSenderBlock)callback)
{
    NSURL *receiptUrl = [[NSBundle mainBundle] appStoreReceiptURL];
    NSData *receiptData = [NSData dataWithContentsOfURL:receiptUrl];
    if (!receiptData) {
      callback(@[RCTMakeError(@"receipt_not_available", nil, nil)]);
    } else {
      callback(@[[NSNull null], [receiptData base64EncodedStringWithOptions:0]]);
    }
}

// SKProductsRequestDelegate protocol method
- (void)productsRequest:(SKProductsRequest *)request
     didReceiveResponse:(SKProductsResponse *)response
{
    NSString *key = RCTKeyForInstance(request);
    RCTResponseSenderBlock callback = _callbacks[key];
    if (callback) {
        products = [NSMutableArray arrayWithArray:response.products];
        NSMutableArray *productsArrayForJS = [NSMutableArray array];
        for(SKProduct *item in response.products) {
            NSDictionary *product = @{
                                      @"identifier": item.productIdentifier,
                                      @"price": item.price,
                                      @"currencySymbol": [item.priceLocale objectForKey:NSLocaleCurrencySymbol],
                                      @"currencyCode": [item.priceLocale objectForKey:NSLocaleCurrencyCode],
                                      @"priceString": item.priceString,
                                      @"countryCode": [item.priceLocale objectForKey: NSLocaleCountryCode],
                                      @"downloadable": item.downloadable ? @"true" : @"false" ,
                                      @"description": item.localizedDescription ? item.localizedDescription : @"",
                                      @"title": item.localizedTitle ? item.localizedTitle : @"",
                                      };
            [productsArrayForJS addObject:product];
        }
        callback(@[[NSNull null], productsArrayForJS]);
        [_callbacks removeObjectForKey:key];
    } else {
        RCTLogWarn(@"No callback registered for load product request.");
    }
}

// SKProductsRequestDelegate network error
- (void)request:(SKRequest *)request didFailWithError:(NSError *)error{
    NSString *key = RCTKeyForInstance(request);
    RCTResponseSenderBlock callback = _callbacks[key];
    if(callback) {
        callback(@[RCTJSErrorFromNSError(error)]);
        [_callbacks removeObjectForKey:key];
    }
}

- (NSDictionary *)getPurchaseData:(SKPaymentTransaction *)transaction {
    NSMutableDictionary *purchase = [NSMutableDictionary dictionaryWithDictionary: @{
                                                                                     @"transactionDate": @(transaction.transactionDate.timeIntervalSince1970 * 1000),
                                                                                     @"transactionIdentifier": transaction.transactionIdentifier,
                                                                                     @"productIdentifier": transaction.payment.productIdentifier,
                                                                                     @"transactionReceipt": [[transaction transactionReceipt] base64EncodedStringWithOptions:0]
                                                                                     }];
    // originalTransaction is available for restore purchase and purchase of cancelled/expired subscriptions
    SKPaymentTransaction *originalTransaction = transaction.originalTransaction;
    if (originalTransaction) {
        purchase[@"originalTransactionDate"] = @(originalTransaction.transactionDate.timeIntervalSince1970 * 1000);
        purchase[@"originalTransactionIdentifier"] = originalTransaction.transactionIdentifier;
    }

    return purchase;
}

- (void)dealloc
{
    [[SKPaymentQueue defaultQueue] removeTransactionObserver:self];
}

#pragma mark Private

static NSString *RCTKeyForInstance(id instance)
{
    return [NSString stringWithFormat:@"%p", instance];
}

@end
