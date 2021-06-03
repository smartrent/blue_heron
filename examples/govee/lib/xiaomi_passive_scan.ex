defmodule XiaomiPassiveScan do
  @moduledoc """
  Sample passive BLE scanner for getting values broadcasted by the Xiaomi "Mi Flora" aka VegTrug

  They can be found [here](https://www.aliexpress.com/af/mi-flora.html)
  """

  use GenServer
  require Logger

  alias BlueHeron.HCI.Command.{
    ControllerAndBaseband.WriteLocalName,
    LEController.SetScanEnable
  }

  alias BlueHeron.HCI.Event.{
    LEMeta.AdvertisingReport,
    LEMeta.AdvertisingReport.Device
  }

  # Sets the name of the BLE device
  @write_local_name %WriteLocalName{name: "Xiaomi Listener"}

  @default_uart_config %{
    device: "tty.usbmodem14101",
    uart_opts: [speed: 115_200],
    init_commands: [@write_local_name]
  }

  @default_usb_config %{
    vid: 0x0BDA,
    pid: 0xB82C,
    init_commands: [@write_local_name]
  }

  @listen_to_device_addresses [
    "216039227630131": %{
      name: "my avocado plant",
      pubsub_topic: "avacoda_plant",
      # eg MyApp.PubSub for pubsub_module
      pubsub_module: false
    }
  ]

  @listen_to_devices_keys Keyword.keys(@listen_to_device_addresses)
                          |> Enum.map(fn key -> Atom.to_string(key) |> String.to_integer() end)

  @doc """
  Start a linked listener

  ## UART

      iex> {:ok, pid} = XiaomiPassiveScan.start_link(:uart, device: "ttyACM0")
      {:ok, #PID<0.111.0>}

  ## USB

      iex> {:ok, pid} = XiaomiPassiveScan.start_link(:usb)
      {:ok, #PID<0.111.0>}
  """
  def start_link(transport_type, config \\ %{})

  def start_link(:uart, config) do
    config = struct(BlueHeronTransportUART, Map.merge(@default_uart_config, config))
    GenServer.start_link(__MODULE__, config, [])
  end

  def start_link(:usb, config) do
    config = struct(BlueHeronTransportUSB, Map.merge(@default_usb_config, config))
    GenServer.start_link(__MODULE__, config, [])
  end

  @impl GenServer
  def init(config) do
    # Create a context for BlueHeron to operate with
    {:ok, ctx} = BlueHeron.transport(config)

    # Subscribe to HCI and ACL events
    BlueHeron.add_event_handler(ctx)

    # Start the ATT Client (this is what we use to read/write data with)
    {:ok, conn} = BlueHeron.ATT.Client.start_link(ctx)

    {:ok, %{conn: conn, ctx: ctx, connected?: false, count: 0}}
  end

  @impl GenServer

  # Sent when a transport connection is established
  def handle_info({:BLUETOOTH_EVENT_STATE, :HCI_STATE_WORKING}, state) do
    # Enable BLE Scanning. This will deliver messages to the process mailbox
    # when other devices broadcast
    Logger.info("Scanning for devices")

    BlueHeron.hci_command(state.ctx, %SetScanEnable{
      le_scan_enable: true
    })

    {:noreply, state}
  end

  # listen for devices that are very close (rss > 200), not yet configured, and has matching MAC address
  def handle_info(
        {:HCI_EVENT_PACKET,
         %AdvertisingReport{
           devices: [
             %Device{
               address: addr,
               data: [data],
               event_type: 4,
               rss: rss
             }
           ]
         }},
        state
      )
      when rss > 200 and addr not in @listen_to_devices_keys do
    mac = addr |> :binary.encode_unsigned(:little)
    <<_head::binary-size(4), rest::binary>> = mac

    # the devices have mac addresses in this range C4:7C:XX:XX:XX:XX
    # thus we match "C4" eg 0xc4 eg 196
    # and "7C" eg 0x7c eg 124
    # the mac in binary is in reverse order
    if rest == <<124, 196>> do
      Logger.info(
        "FOUND SUPPORTED DEVICE, currently not configured:  device_adress: #{inspect(addr)} - name: #{
          data
        }\n
        Config in @listen_to_device_addresses with something like:\n
            \"#{addr}\": %\{name: \"my avocado plant\", pubsub_topic: \"avacoda_plant\", pubsub_module: MyApp.PubSub \}
        "
      )
    end

    {:noreply, state}
  end

  def handle_info(
        {:HCI_EVENT_PACKET,
         %AdvertisingReport{
           devices: [%Device{address: addr, event_type: 0, data: data}]
         }},
        state
      )
      when addr in @listen_to_devices_keys do
    mac = addr |> :binary.encode_unsigned(:little)

    # https://github.com/custom-components/ble_monitor/blob/ae5eaadc78dd144714a9ddc3039b824966955efc/custom_components/ble_monitor/const.py#L59
    # the 152, 0 below significes the "HHCCJCY01" (152 == 0x98 and 0 == 0x00)
    case data do
      [
        <<1, 6>>,
        <<2, 149, 254>>,
        <<22, 149, 254, 113, 32, 152, 0, count::binary-size(1), adr::binary-size(6), 13, cmd, 16,
          _value_length, value::binary>>
      ]
      when adr == mac and count != state.count ->
        integer_count = count |> :binary.decode_unsigned(:little)

        device = @listen_to_device_addresses[:"#{addr}"]
        # %{name: "my avocado plant", pubsub_module: false, pubsub_topic: "avacoda_plant"}

        case cmd do
          4 ->
            # https://github.com/custom-components/ble_monitor/blob/1c421f62880cfaf9e95558619122266b4663f67c/custom_components/ble_monitor/__init__.py#L461
            # temperature
            temp = (value |> :binary.decode_unsigned(:little)) / 10
            Logger.info("#{device.name} - temperature: #{temp}")

          # if device.pubsub_module do
          #   Phoenix.PubSub.broadcast(device.pubsub_module, device.pubsub_topic, %{
          #     name: device.name,
          #     measurement: :temp,
          #     value: temp
          #   })
          # end

          # 5 ->
          #   # KettleStatusAndTemperature
          #   <<status::binary-size(1), temp::binary-size(1)>> = value
          #   Logger.info("count: #{integer_count} - status - #{status} - kettletemp: #{temp}")

          # 6 ->
          #   # Humidity
          #   humidity = (value |> :binary.decode_unsigned(:little)) / 10
          #   Logger.info("count: #{integer_count} - humidity: #{humidity}")

          7 ->
            # lux / light
            lux = value |> :binary.decode_unsigned(:little)
            Logger.info("#{device.name} - lux: #{lux}")

          # if device.pubsub_module do
          #   Phoenix.PubSub.broadcast(device.pubsub_module, device.pubsub_topic, %{
          #     name: device.name,
          #     measurement: :lux,
          #     value: lux
          #   })
          # end

          8 ->
            # Moisture
            moisture = value |> :binary.decode_unsigned(:little)
            Logger.info("#{device.name} - moisture: #{moisture}")

          # if device.pubsub_module do
          #   Phoenix.PubSub.broadcast(device.pubsub_module, device.pubsub_topic, %{
          #     name: device.name,
          #     measurement: :moisture,
          #     value: moisture
          #   })
          # end

          9 ->
            # Fertility
            fertility = value |> :binary.decode_unsigned(:little)
            Logger.info("#{device.name} - fertility: #{fertility}")

          # if device.pubsub_module do
          #   Phoenix.PubSub.broadcast(device.pubsub_module, device.pubsub_topic, %{
          #     name: device.name,
          #     measurement: :fertility,
          #     value: fertility
          #   })
          # end

          # 10 ->
          #   # battery
          #   battery = value |> :binary.decode_unsigned(:little)
          #   Logger.info("count: #{integer_count} - battery?: #{battery}")

          # 13 ->
          #   # Temperature And Humidity
          #   <<temp::binary-size(2), humidity::binary-size(2)>> = value
          #   temp = (temp |> :binary.decode_unsigned(:little)) / 10
          #   humidity = (humidity |> :binary.decode_unsigned(:little)) / 10
          #   Logger.info("count: #{integer_count} - temp: #{temp} - humidity: #{humidity}")

          # 16 ->
          #   # formaldehyde
          #   formaldehyde = (value |> :binary.decode_unsigned(:little)) / 100
          #   Logger.info("count: #{integer_count} - formaldehyde: #{formaldehyde}")

          _ ->
            Logger.info("HCI_EVENT_PACKET value: #{inspect(value)}")
        end

        {:noreply, Map.put(state, :count, count)}

      _ ->
        {:noreply, state}
    end
  end

  # ignore other HCI Events
  def handle_info({:HCI_EVENT_PACKET, _packet}, state) do
    {:noreply, state}
  end

  # ignore other HCI ACL data (ATT handles this for us)
  def handle_info({:HCI_ACL_DATA_PACKET, _packet}, state) do
    {:noreply, state}
  end
end
