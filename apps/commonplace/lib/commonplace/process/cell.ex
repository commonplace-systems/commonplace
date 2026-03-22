defmodule Commonplace.Process.Cell do
  @moduledoc """
  Spreadsheet-cell-style reactive process.

  A Cell subscribes to input documents and recomputes its output
  whenever they change. Users define a `compute/1` callback that
  receives a map of input names to their content.

  ## Usage

      defmodule Commonplace.UserProcess.MyCell do
        use Commonplace.Process.Cell,
          inputs: ["price.txt", "quantity.txt"],
          output: "total.txt"

        def compute(inputs) do
          price = String.to_float(inputs["price.txt"] || "0.0")
          qty = String.to_integer(inputs["quantity.txt"] || "0")
          Float.to_string(price * qty)
        end
      end
  """

  defmacro __using__(opts) do
    inputs = Keyword.get(opts, :inputs, [])
    output = Keyword.get(opts, :output)

    quote do
      use GenServer

      @cell_inputs unquote(inputs)
      @cell_output unquote(output)

      def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

      @impl true
      def init(opts) do
        store = Keyword.fetch!(opts, :store)
        root_uuid = Keyword.fetch!(opts, :root_uuid)
        name = Keyword.fetch!(opts, :name)

        state = %{
          store: store,
          root_uuid: root_uuid,
          name: name,
          inputs: @cell_inputs,
          output: @cell_output,
          input_hashes: %{},
          poll_interval: 200
        }

        # Initial computation
        send(self(), :compute)
        schedule_poll(state)

        {:ok, state}
      end

      @impl true
      def handle_info(:compute, state) do
        state = do_compute(state)
        {:noreply, state}
      end

      @impl true
      def handle_info(:poll, state) do
        state = check_and_recompute(state)
        schedule_poll(state)
        {:noreply, state}
      end

      defp check_and_recompute(state) do
        # Check if any input content has changed
        current_hashes = read_input_hashes(state)

        if current_hashes != state.input_hashes do
          do_compute(%{state | input_hashes: current_hashes})
        else
          state
        end
      end

      defp do_compute(state) do
        # Read all inputs
        inputs = read_inputs(state)

        # Compute output
        result = compute(inputs)

        # Write to output doc
        write_output(state, result)

        # Update hashes
        hashes = read_input_hashes(state)
        %{state | input_hashes: hashes}
      end

      defp read_inputs(state) do
        root_doc = load_schema(state.root_uuid, state.store)

        Map.new(state.inputs, fn input_name ->
          content =
            case Commonplace.Tree.Schema.get_entry(root_doc, input_name) do
              {:ok, entry} ->
                case Commonplace.Store.CommitStore.latest_commit(state.store, entry.node_id) do
                  {:ok, commit} ->
                    doc = Yelixer.Doc.new()
                    {:ok, doc} = Yelixer.Encoding.apply_update(doc, commit.update)
                    Commonplace.Document.ContentType.get_content(doc) || ""

                  :none ->
                    ""
                end

              :error ->
                ""
            end

          {input_name, content}
        end)
      end

      defp read_input_hashes(state) do
        root_doc = load_schema(state.root_uuid, state.store)

        Map.new(state.inputs, fn input_name ->
          hash =
            case Commonplace.Tree.Schema.get_entry(root_doc, input_name) do
              {:ok, entry} ->
                case Commonplace.Store.CommitStore.latest_commit(state.store, entry.node_id) do
                  {:ok, commit} -> commit.id
                  :none -> nil
                end

              :error ->
                nil
            end

          {input_name, hash}
        end)
      end

      defp write_output(state, content) do
        root_doc = load_schema(state.root_uuid, state.store)

        case Commonplace.Tree.Schema.get_entry(root_doc, state.output) do
          {:ok, entry} ->
            # Update existing output doc
            doc = Yelixer.Doc.new()
            doc = Commonplace.Document.ContentType.create(doc, :text, state.output)
            doc = Commonplace.Document.ContentType.insert_text(doc, 0, content)
            update = Yelixer.Encoding.encode_update(doc)
            Commonplace.Store.CommitStore.create_commit(state.store, entry.node_id, update, nil)

          :error ->
            # Create output doc
            uuid = UUID.uuid4()
            doc = Yelixer.Doc.new()
            doc = Commonplace.Document.ContentType.create(doc, :text, state.output)
            doc = Commonplace.Document.ContentType.insert_text(doc, 0, content)
            update = Yelixer.Encoding.encode_update(doc)
            Commonplace.Store.CommitStore.create_commit(state.store, uuid, update, nil)

            # Add to schema
            root_doc = load_schema(state.root_uuid, state.store)
            root_doc = Commonplace.Tree.Schema.add_file(root_doc, state.output, uuid)
            update = Yelixer.Encoding.encode_update(root_doc)
            Commonplace.Store.CommitStore.create_commit(state.store, state.root_uuid, update, nil)
        end
      end

      defp load_schema(uuid, store) do
        case Commonplace.Store.CommitStore.latest_commit(store, uuid) do
          {:ok, commit} ->
            doc = Commonplace.Tree.Schema.new_schema()
            {:ok, doc} = Yelixer.Encoding.apply_update(doc, commit.update)
            doc

          :none ->
            Commonplace.Tree.Schema.new_schema()
        end
      end

      defp schedule_poll(state) do
        Process.send_after(self(), :poll, state.poll_interval)
      end
    end
  end
end
