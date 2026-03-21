defmodule Yelixer.TransactionTest do
  use ExUnit.Case, async: true

  alias Yelixer.{Doc, Transaction, StateVector}

  test "transact returns result and updated doc" do
    doc = Doc.new(client_id: 1)

    {result, doc2} =
      Transaction.transact(doc, fn txn ->
        {txn, :ok}
      end)

    assert result == :ok
    assert doc2.client_id == 1
  end

  test "transaction tracks clock advancement" do
    doc = Doc.new(client_id: 1)

    {_result, doc} =
      Transaction.transact(doc, fn txn ->
        txn = Transaction.insert(txn, {:named, "text"}, nil, {:string, "hello"})
        {txn, :ok}
      end)

    sv = Yelixer.BlockStore.state_vector(doc.store)
    assert StateVector.get(sv, 1) == 5
  end

  test "multiple inserts in same transaction advance clock correctly" do
    doc = Doc.new(client_id: 1)

    {_, doc} =
      Transaction.transact(doc, fn txn ->
        txn = Transaction.insert(txn, {:named, "text"}, nil, {:string, "abc"})
        txn = Transaction.insert(txn, {:named, "text"}, nil, {:string, "de"})
        {txn, :ok}
      end)

    sv = Yelixer.BlockStore.state_vector(doc.store)
    assert StateVector.get(sv, 1) == 5
  end
end
