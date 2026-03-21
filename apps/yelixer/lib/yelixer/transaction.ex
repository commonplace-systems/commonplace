defmodule Yelixer.Transaction do
  alias Yelixer.{Doc, ID, Item, BlockStore, DeleteSet, StateVector}

  @type t :: %__MODULE__{
          doc: Doc.t(),
          before_state: StateVector.t(),
          delete_set: DeleteSet.t()
        }

  defstruct [:doc, :before_state, :delete_set]

  def transact(%Doc{} = doc, fun) when is_function(fun, 1) do
    txn = %__MODULE__{
      doc: doc,
      before_state: BlockStore.state_vector(doc.store),
      delete_set: DeleteSet.new()
    }

    {txn, result} = fun.(txn)
    doc = commit(txn)
    {result, doc}
  end

  def insert(%__MODULE__{doc: doc} = txn, parent, parent_sub, content) do
    clock = StateVector.get(BlockStore.state_vector(doc.store), doc.client_id)
    id = ID.new(doc.client_id, clock)
    item = Item.new(id, nil, nil, content, parent, parent_sub)
    store = BlockStore.push(doc.store, item)
    %{txn | doc: %{doc | store: store}}
  end

  defp commit(%__MODULE__{doc: doc, delete_set: ds}) do
    %{doc | delete_set: DeleteSet.merge(doc.delete_set, ds)}
  end
end
