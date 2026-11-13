package com.justspeaktoit.android.tips

import android.app.Activity
import android.content.Context
import com.android.billingclient.api.BillingClient
import com.android.billingclient.api.BillingClientStateListener
import com.android.billingclient.api.BillingFlowParams
import com.android.billingclient.api.BillingResult
import com.android.billingclient.api.ConsumeParams
import com.android.billingclient.api.PendingPurchasesParams
import com.android.billingclient.api.ProductDetails
import com.android.billingclient.api.Purchase
import com.android.billingclient.api.PurchasesUpdatedListener
import com.android.billingclient.api.QueryProductDetailsParams
import com.android.billingclient.api.QueryPurchasesParams
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import java.io.IOException

/**
 * The tip jar on Google Play Billing. Tips are consumable one-time products with the same IDs as the Apple tip
 * jar, consumed as soon as Play confirms them so the same tip can be bought again; they unlock nothing. Billing
 * callbacks can arrive on any thread, so state changes go through [MutableStateFlow.update].
 */
class PlayBillingTipStore(context: Context) : PurchasesUpdatedListener {
    private val appContext = context.applicationContext
    private val _state = MutableStateFlow(TipJarUiState())
    val state: StateFlow<TipJarUiState> = _state.asStateFlow()

    private val tiers: List<TipTier> = try {
        appContext.assets.open(TipCatalogParser.ASSET).bufferedReader().use { TipCatalogParser.parse(it.readText()) }
    } catch (_: IOException) {
        emptyList()
    }

    private val client: BillingClient = BillingClient.newBuilder(appContext)
        .setListener(this)
        .enablePendingPurchases(PendingPurchasesParams.newBuilder().enableOneTimeProducts().build())
        .enableAutoServiceReconnection()
        .build()

    @Volatile private var details: Map<String, ProductDetails> = emptyMap()

    /** Connects and loads prices. Safe to call each time the tip jar is shown. */
    fun connect() {
        if (tiers.isEmpty()) {
            _state.update(TipJarReducer::unavailable)
            return
        }
        if (client.isReady) {
            loadProducts()
            return
        }
        client.startConnection(object : BillingClientStateListener {
            override fun onBillingSetupFinished(result: BillingResult) {
                if (result.responseCode == BillingClient.BillingResponseCode.OK) {
                    loadProducts()
                    consumeLeftovers()
                } else {
                    _state.update(TipJarReducer::unavailable)
                }
            }

            override fun onBillingServiceDisconnected() {
                // Automatic service reconnection retries on the next call.
            }
        })
    }

    fun purchase(activity: Activity, productId: String) {
        val product = details[productId] ?: return
        var started = false
        _state.update { current ->
            TipJarReducer.purchaseStarted(current, productId).also { started = it != current }
        }
        if (!started) return
        val params = BillingFlowParams.newBuilder()
            .setProductDetailsParamsList(
                listOf(BillingFlowParams.ProductDetailsParams.newBuilder().setProductDetails(product).build()),
            )
            .build()
        val result = client.launchBillingFlow(activity, params)
        if (result.responseCode != BillingClient.BillingResponseCode.OK) {
            _state.update { TipJarReducer.finished(it, TipOutcome.Failed) }
        }
    }

    override fun onPurchasesUpdated(result: BillingResult, purchases: List<Purchase>?) {
        val outcome = when (result.responseCode) {
            BillingClient.BillingResponseCode.OK -> {
                val tips = purchases.orEmpty()
                tips.filter { it.purchaseState == Purchase.PurchaseState.PURCHASED }.forEach(::consume)
                when {
                    tips.any { it.purchaseState == Purchase.PurchaseState.PURCHASED } -> TipOutcome.Purchased
                    tips.any { it.purchaseState == Purchase.PurchaseState.PENDING } -> TipOutcome.Pending
                    else -> TipOutcome.Failed
                }
            }
            BillingClient.BillingResponseCode.USER_CANCELED -> TipOutcome.Cancelled
            else -> TipOutcome.Failed
        }
        _state.update { TipJarReducer.finished(it, outcome) }
    }

    fun close() {
        client.endConnection()
    }

    private fun loadProducts() {
        val params = QueryProductDetailsParams.newBuilder()
            .setProductList(
                tiers.map {
                    QueryProductDetailsParams.Product.newBuilder()
                        .setProductId(it.productId)
                        .setProductType(BillingClient.ProductType.INAPP)
                        .build()
                },
            )
            .build()
        client.queryProductDetailsAsync(params) { result, response ->
            if (result.responseCode != BillingClient.BillingResponseCode.OK) {
                _state.update(TipJarReducer::unavailable)
                return@queryProductDetailsAsync
            }
            val list = response.productDetailsList.orEmpty()
            details = list.associateBy { it.productId }
            val products = list.mapNotNull { product ->
                val offer = product.oneTimePurchaseOfferDetails ?: return@mapNotNull null
                StoreProduct(product.productId, product.name, offer.formattedPrice, offer.priceAmountMicros)
            }
            _state.update { TipJarReducer.loaded(it, TipOffers.merge(tiers, products)) }
        }
    }

    /** A tip whose consume didn't finish (the app closed first) would block buying that tier again. */
    private fun consumeLeftovers() {
        val params = QueryPurchasesParams.newBuilder().setProductType(BillingClient.ProductType.INAPP).build()
        client.queryPurchasesAsync(params) { result, purchases ->
            if (result.responseCode != BillingClient.BillingResponseCode.OK) return@queryPurchasesAsync
            purchases.orEmpty().filter { it.purchaseState == Purchase.PurchaseState.PURCHASED }.forEach(::consume)
        }
    }

    private fun consume(purchase: Purchase) {
        val params = ConsumeParams.newBuilder().setPurchaseToken(purchase.purchaseToken).build()
        client.consumeAsync(params) { _, _ -> }
    }
}
