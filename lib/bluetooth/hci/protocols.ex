defprotocol Bluetooth.HCI.Serializable do
  @doc """
  Serialize an HCI data structure as a binary
  """
  def serialize(hci_struct)
end

defprotocol Bluetooth.HCI.Deserializable do
  @doc """
  Deserialize a binary into HCI data structures
  """
  def deserialize(bin)
end

defprotocol Bluetooth.HCI.CommandComplete.ReturnParameters do
  @doc """
  Protocol for handling command return_parameters in CommandComplete event

  This is mainly to allow us to do function generation at compile time
  for handling this parsing for specific commands.
  """
  def parse(cc_struct)
end

defimpl Bluetooth.HCI.Deserializable, for: BitString do
  # Define deserialize/1 for HCI.Command modules
  for mod <- Bluetooth.HCI.Command.__modules__(), opcode = mod.__opcode__() do
    def deserialize(unquote(opcode) <> _ = bin) do
      unquote(mod).deserialize(bin)
    end
  end

  # Define deserialize/1 for HCI.Event modules
  for mod <- Bluetooth.HCI.Event.__modules__(), code = mod.__code__() do
    if function_exported?(mod, :__subevent_code__, 0) do
      # These are LEMeta subevents
      def deserialize(
            <<unquote(code), _size, unquote(mod.__subevent_code__()), _rest::binary>> = bin
          ) do
        unquote(mod).deserialize(bin)
      end
    else
      # Normal events
      def deserialize(<<unquote(code), _rest::binary>> = bin) do
        unquote(mod).deserialize(bin)
      end
    end
  end

  def deserialize(bin) do
    error = """
    Unable to deserialize #{inspect(bin)}

    If this is unexpected, then be sure that the target deserialized module
    is defined in the @modules attribute of the appropiate type:

    * Bluetooth.HCI.Command
    * Bluetooth.HCI.Event
    """

    {:error, error}
  end
end

defimpl Bluetooth.HCI.CommandComplete.ReturnParameters, for: Bluetooth.HCI.Event.CommandComplete do
  def parse(cc) do
    %{cc | return_parameters: do_parse(cc.opcode, cc.return_parameters)}
  end

  # Generate return_parameter parsing function for all available command
  # modules based on the requirements in Bluetooth.HCI.Command behaviour
  for mod <- Bluetooth.HCI.Command.__modules__(), opcode = mod.__opcode__() do
    defp do_parse(unquote(opcode), rp_bin) do
      unquote(mod).return_parameters(rp_bin)
    end
  end
end