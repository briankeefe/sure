require_relative "../../config/environment"
require "minitest/autorun"
require "minitest/mock"
require "ostruct"

# Uses actual model/provider/job logic with synthetic payloads; no Plaid network calls.
class PlaidConsentGuardsTest < Minitest::Test
  def setup
    @environment = ENV.to_h.slice("PLAID_REQUIRE_BILLED_PRODUCTS", "PLAID_ALLOW_PAID_TRANSACTIONS_REFRESH")
    ENV["PLAID_REQUIRE_BILLED_PRODUCTS"] = "true"
    ENV.delete("PLAID_ALLOW_PAID_TRANSACTIONS_REFRESH")
    @item = PlaidItem.new(access_token: "synthetic-token", next_cursor: "preserved-cursor")
    accounts = Object.new
    accounts.define_singleton_method(:pluck) { |_| [] }
    @item.define_singleton_method(:plaid_accounts) { accounts }
  end

  def teardown
    %w[PLAID_REQUIRE_BILLED_PRODUCTS PLAID_ALLOW_PAID_TRANSACTIONS_REFRESH].each { |key| ENV.delete(key) }
    ENV.update(@environment)
  end

  def metadata(billed:, consented:, available: [])
    @item.assign_attributes(billed_products: billed, available_products: available,
      raw_payload: { "consented_products" => consented })
  end

  def snapshot(type)
    account = OpenStruct.new(account_id: "synthetic-account", type: type, subtype: "student",
      balances: OpenStruct.new(current: 1))
    provider = Object.new
    provider.define_singleton_method(:get_item_accounts) { |_| OpenStruct.new(accounts: [ account ]) }
    yield provider if block_given?
    PlaidItem::AccountsSnapshot.new(@item, plaid_provider: provider)
  end

  def test_availability_does_not_allow_any_product_read
    metadata(billed: [], consented: [], available: %w[transactions investments liabilities])
    %w[credit investment loan].each do |type|
      data = snapshot(type).get_account_data("synthetic-account")
      assert_nil data.transactions_data
      assert_nil data.investments_data
      assert_nil data.liabilities_data
    end
  end

  def test_consent_does_not_initialize_a_new_billed_product_in_strict_mode
    metadata(billed: [], consented: %w[transactions investments liabilities])
    %w[credit investment loan].each do |type|
      data = snapshot(type).get_account_data("synthetic-account")
      assert_nil data.transactions_data
      assert_nil data.investments_data
      assert_nil data.liabilities_data
    end
  end

  def test_billing_does_not_substitute_for_current_consent
    metadata(billed: %w[transactions investments liabilities], consented: [])
    %w[transactions investments liabilities].each { |product| refute @item.consented_to_product?(product) }
  end

  def test_retirement_investments_only_survives_fresh_item_metadata
    metadata(billed: [ "investments" ], consented: [ "investments" ], available: [ "transactions" ])
    investments = OpenStruct.new(transactions: [], holdings: [], securities: [])
    result = snapshot("investment") do |provider|
      provider.define_singleton_method(:get_item_investments) { |_| investments }
    end.get_account_data("synthetic-account")
    assert_nil result.transactions_data
    assert_nil result.liabilities_data
    assert_empty result.investments_data.holdings
    assert_equal "preserved-cursor", @item.next_cursor
  end

  def test_bank_transactions_only_polls_without_investments_or_liabilities
    metadata(billed: [ "transactions" ], consented: %w[transactions investments liabilities],
      available: %w[investments liabilities transactions_refresh])
    result = snapshot("investment") do |provider|
      provider.define_singleton_method(:get_transactions) do |_, next_cursor:|
        raise "cursor changed" unless next_cursor == "preserved-cursor"
        OpenStruct.new(added: [ OpenStruct.new(account_id: "synthetic-account", transaction_id: "synthetic-transaction") ], modified: [], removed: [], cursor: "next")
      end
    end.get_account_data("synthetic-account")
    assert_equal [ "synthetic-transaction" ], result.transactions_data.added.map(&:transaction_id)
    assert_nil result.investments_data
    assert_nil result.liabilities_data
  end

  def test_current_billed_liabilities_remain_readable
    metadata(billed: [ "liabilities" ], consented: [ "liabilities" ], available: [ "transactions" ])
    result = snapshot("loan") do |provider|
      provider.define_singleton_method(:get_item_liabilities) do |_|
        OpenStruct.new(student: [ OpenStruct.new(account_id: "synthetic-account", interest_rate_percentage: 4) ])
      end
    end.get_account_data("synthetic-account")
    assert_equal 4, result.liabilities_data.student.interest_rate_percentage
    assert_nil result.transactions_data
    assert_nil result.investments_data
  end

  def test_refreshed_sdk_metadata_does_not_grant_available_transactions
    metadata(billed: [ "transactions" ], consented: [ "transactions" ])
    receipt = Plaid::Item.new(item_id: "synthetic-item", institution_id: "synthetic-institution",
      available_products: [ "transactions" ], billed_products: [ "investments" ],
      consented_products: [ "investments" ], webhook: "", error: nil)
    @item.stub(:save!, true) { @item.upsert_plaid_snapshot!(receipt) }
    assert_equal [ "transactions" ], @item.available_products
    assert_equal [ "investments" ], @item.billed_products
    refute @item.can_read_product?("transactions")
    assert @item.can_read_product?("investments")
  end

  def test_non_strict_mode_still_requires_consent
    ENV["PLAID_REQUIRE_BILLED_PRODUCTS"] = "false"
    metadata(billed: [], consented: [ "transactions" ])
    assert @item.can_read_product?("transactions")
    refute @item.can_read_product?("investments")
  end

  def test_direct_provider_refresh_is_rejected_before_client_dispatch
    provider = Provider::Plaid.allocate
    assert_raises(Provider::Plaid::PaidRefreshDisabledError) { provider.refresh_transactions("synthetic-token") }
  end

  def test_opted_in_refresh_requires_read_permission
    ENV["PLAID_ALLOW_PAID_TRANSACTIONS_REFRESH"] = "true"
    metadata(billed: [ "investments" ], consented: [ "investments" ], available: [ "transactions" ])
    refute @item.transactions_refresh_allowed?
    metadata(billed: [ "transactions" ], consented: [ "transactions" ])
    assert @item.transactions_refresh_allowed?
  end

  def test_manual_sync_and_previously_queued_refresh_fall_back_to_polling
    metadata(billed: [ "transactions" ], consented: [ "transactions" ])
    calls = []
    @item.define_singleton_method(:sync_later_with_follow_up) { calls << :poll }
    @item.define_singleton_method(:plaid_provider) { raise "refresh provider reached" }
    @item.request_transactions_refresh_later
    @item.sync_later_with_provider_refresh
    PlaidTransactionsRefreshJob.new.perform(@item)
    assert_equal [ :poll, :poll ], calls
  end
end
