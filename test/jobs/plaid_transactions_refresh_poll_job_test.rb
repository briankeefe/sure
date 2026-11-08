require "test_helper"

class PlaidTransactionsRefreshPollJobTest < ActiveJob::TestCase
  setup do
    @plaid_item = plaid_items(:one)
    @plaid_item.update!(
      next_cursor: "saved-cursor",
      billed_products: [ "transactions" ],
      raw_payload: { "consented_products" => [ "transactions" ] }
    )
    @provider = mock
    PlaidItem.any_instance.stubs(:plaid_provider).returns(@provider)
  end

  test "queued poll skips investment-only items and schedules a safe follow-up" do
    assert_disallowed_queued_poll(
      billed_products: [ "investments" ],
      available_products: [ "transactions" ],
      raw_payload: { "consented_products" => [ "investments" ] }
    )
  end

  test "queued poll skips consented but unbilled transactions in strict mode" do
    assert_disallowed_queued_poll(
      billed_products: [],
      raw_payload: { "consented_products" => [ "transactions" ] }
    )
  end

  test "queued poll reloads revoked consent before dispatch" do
    assert_disallowed_queued_poll(raw_payload: { "consented_products" => [] })
  end

  test "queued poll skips missing consent metadata" do
    assert_disallowed_queued_poll(raw_payload: nil)
  end

  test "continues polling from a cursor advanced by a concurrent sync" do
    @plaid_item.update!(next_cursor: "advanced-cursor")
    @provider.expects(:get_transactions)
      .with(@plaid_item.access_token, next_cursor: "advanced-cursor")
      .returns(stub(cursor: "refreshed-cursor"))

    assert_enqueued_with(job: SyncJob) do
      perform_enqueued_jobs(only: PlaidTransactionsRefreshFollowUpSyncJob) do
        PlaidTransactionsRefreshPollJob.perform_now(@plaid_item, cursor: "saved-cursor")
      end
    end
  end

  test "schedules normal sync when refreshed deltas are available" do
    @provider.expects(:get_transactions)
      .with(@plaid_item.access_token, next_cursor: "saved-cursor")
      .returns(stub(cursor: "advanced-cursor"))

    with_env_overrides("PLAID_REQUIRE_BILLED_PRODUCTS" => "true") do
      assert_enqueued_with(job: PlaidTransactionsRefreshFollowUpSyncJob) do
        perform_enqueued_jobs(only: PlaidTransactionsRefreshPollJob) do
          PlaidTransactionsRefreshPollJob.perform_later(@plaid_item, cursor: "saved-cursor")
        end
      end
    end
  end

  test "polls again while the cursor has not advanced" do
    @provider.expects(:get_transactions).returns(stub(cursor: "saved-cursor"))

    assert_enqueued_with(
      job: PlaidTransactionsRefreshPollJob,
      args: [ @plaid_item, { cursor: "saved-cursor", attempts_remaining: 1 } ]
    ) do
      PlaidTransactionsRefreshPollJob.perform_now(
        @plaid_item,
        cursor: "saved-cursor",
        attempts_remaining: 2
      )
    end
  end

  test "falls back to normal sync when polling is exhausted" do
    @provider.expects(:get_transactions).returns(stub(cursor: "saved-cursor"))

    assert_difference "DebugLogEntry.count", 1 do
      assert_enqueued_with(job: PlaidTransactionsRefreshFollowUpSyncJob) do
        PlaidTransactionsRefreshPollJob.perform_now(
          @plaid_item,
          cursor: "saved-cursor",
          attempts_remaining: 1
        )
      end
    end
  end

  test "falls back to normal sync when polling fails" do
    @provider.expects(:get_transactions).raises(Plaid::ApiError.new(code: 500))

    assert_difference "DebugLogEntry.count", 1 do
      assert_enqueued_with(job: PlaidTransactionsRefreshFollowUpSyncJob) do
        PlaidTransactionsRefreshPollJob.perform_now(@plaid_item, cursor: "saved-cursor")
      end
    end
  end

  private
    def assert_disallowed_queued_poll(changes)
      with_env_overrides("PLAID_REQUIRE_BILLED_PRODUCTS" => "true") do
        @provider.expects(:get_transactions).never
        assert_enqueued_with(job: PlaidTransactionsRefreshFollowUpSyncJob) do
          assert_no_difference "DebugLogEntry.count" do
            PlaidTransactionsRefreshPollJob.perform_later(@plaid_item, cursor: "saved-cursor", attempts_remaining: 2)
            # The queued object had permission; execution must use fresh metadata.
            PlaidItem.find(@plaid_item.id).update!(changes)
            perform_enqueued_jobs(only: PlaidTransactionsRefreshPollJob)
          end
        end
        assert_equal "saved-cursor", @plaid_item.reload.next_cursor
        assert_no_enqueued_jobs only: PlaidTransactionsRefreshPollJob
      end
    end
end
