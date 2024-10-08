defmodule Sippet.Transactions.Client.Invite do
  @moduledoc false

  use Sippet.Transactions.Client, initial_state: :calling

  alias Sippet.Message, as: Message
  alias Sippet.Message.StatusLine, as: StatusLine
  alias Sippet.Transactions.Client.State, as: State

  @timer_a 600  # optimization: transaction ends in 37.8s
  @timer_b 64 * @timer_a
  @timer_d 32_000  # timer D should be > 32s

  def retry({past_wait, passed_time}, %State{request: request} = data) do
    send_request(request, data)
    new_delay = past_wait * 2
    {:keep_state_and_data, [{:state_timeout, new_delay,
       {new_delay, passed_time + new_delay}}]}
  end

  def build_ack(request, last_response) do
    ack =
      :ack
      |> Message.build_request(request.start_line.request_uri)
      |> Message.put_header(:via, Message.get_header(request, :via))
      |> Message.put_header(:max_forwards, 70)
      |> Message.put_header(:from, Message.get_header(request, :from))
      |> Message.put_header(:to, Message.get_header(request, :to))
      |> Message.put_header(:call_id, Message.get_header(request, :call_id))

    {sequence, _method} = request.headers.cseq
    ack = ack |> Message.put_header(:cseq, {sequence, :ack})

    ack =
      if Message.has_header?(request, :route) do
        ack |> Message.put_header(:route, Message.get_header(request, :route))
      else
        ack
      end

    ack =
      case last_response.headers.to do
        {_, _, %{"tag": to_tag}} ->
          ack |> Message.update_header(:to, nil,
                  fn {display_name, uri, params} ->
                    {display_name, uri, params |> Map.put("tag", to_tag)}
                  end)
        _otherwise ->
          ack
      end

    if request |> Message.has_header?(:route) do
      ack |> Message.put_header(:route, request.headers.route)
    else
      ack
    end
  end

  def calling(:enter, _old_state, %State{request: request} = data) do
    send_request(request, data)

    actions =
      if reliable?(request) do
        [{:state_timeout, @timer_b, {@timer_b, @timer_b}}]
      else
        [{:state_timeout, @timer_a, {@timer_a, @timer_a}}]
      end

    {:keep_state_and_data, actions}
  end

  def calling(:state_timeout, {_past_wait, passed_time} = time_event, data) do
    if passed_time >= @timer_b do
      timeout(data)
    else
      retry(time_event, data)
    end
  end

  def calling(:cast, {:incoming_response, response}, data) do
    receive_response(response, data)
    case StatusLine.status_code_class(response.start_line) do
      1 -> {:next_state, :proceeding, data}
      2 -> {:stop, :normal, data}
      _ ->
        extras = data.extras |> Map.put(:last_response, response)
        {:next_state, :completed, Map.put(data, :extras, extras)}
    end
  end

  def calling(:cast, {:error, reason}, data),
    do: shutdown(reason, data)

  def calling(event_type, event_content, data),
    do: unhandled_event(event_type, event_content, data)

  def proceeding(:enter, _old_state, _data),
    do: :keep_state_and_data

  def proceeding(:cast, {:incoming_response, response}, data) do
    receive_response(response, data)
    case StatusLine.status_code_class(response.start_line) do
      1 -> {:keep_state, data}
      2 -> {:stop, :normal, data}
      _ ->
        extras = data.extras |> Map.put(:last_response, response)
        {:next_state, :completed, Map.put(data, :extras, extras)}
    end
  end

  def proceeding(:cast, {:error, reason}, data),
    do: shutdown(reason, data)

  def proceeding(event_type, event_content, data),
    do: unhandled_event(event_type, event_content, data)

  def completed(:enter, _old_state,
      %State{request: request, extras: extras} = data) do
    ack = build_ack(request, extras.last_response)
    send_request(ack, data)
    data = %State{extras: extras |> Map.put(:ack, ack)}

    if reliable?(request) do
      {:stop, :normal, data}
    else
      {:keep_state, data, [{:state_timeout, @timer_d, nil}]}
    end
  end

  def completed(:state_timeout, _nil, data),
    do: {:stop, :normal, data}

  def completed(:cast, {:incoming_response, response},
      %State{extras: %{ack: ack}} = data) do
    if StatusLine.status_code_class(response.start_line) >= 3 do
      send_request(ack, data)
    end
    :keep_state_and_data
  end

  def completed(:cast, {:error, _reason}, _data),
    do: :keep_state_and_data

  def completed(event_type, event_content, data),
    do: unhandled_event(event_type, event_content, data)
end
