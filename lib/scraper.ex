defmodule Scraper do
  import Application, only: [fetch_env!: 2]
  import Enum, only: [each: 2, map: 2, join: 2, into: 2]

  use Hound.Helpers

  @cmd_fields [ "Command",               "Arguments",
                  "Working Directory",     "Pipeline Name",
                  "Stage Name",            "Job Name",
                  "Source Directory",      "Destination",
                  "Build File",            "Target" ]

  @env_fields [ "Type", "Name", "Value" ]

  @env_filename "env_variables.csv"
  @cmd_filename "commands.csv"

  def start do
    Hound.start_session
    files = [@env_filename, @cmd_filename] |> reset_files
    files |> write_headers
    get_vars |> get_stages_links |> each(&scrape(&1, files))
    files |> each(&(File.close(&1)))
    Hound.end_session
  end

  defp reset_files(filenames) do
    filenames |> each(&(File.rm(&1)))
    filenames |> map(&({&1, File.open!(&1, [:append])})) |> into(%{})
  end

  defp write_headers(files) do
    [""|@env_fields] |> join(",") |> write_row(files[@env_filename])
    [",Run if"|@cmd_fields] |> join(",") |> write_row(files[@cmd_filename])
  end

  defp get_vars do
    [user, pwd, url, pipeline] =
      [:go_username, :go_password, :go_base_url, :go_pipeline_name]
      |> map(&(fetch_env!(:scraper, &1)))
    %{ username: user, password: pwd, url: url, pipeline_name: pipeline }
  end

  defp login(%{url: url, username: username, password: password}) do
    navigate_to(url)
    find_element(:id, "user_login") |> fill_field(username)
    elem = find_element(:id, "user_password")
    fill_field(elem, password)
    submit_element(elem)
  end

  defp get_stages_links(vars) do
    Map.drop(vars, [:pipeline_name]) |> login
    find_element(:id, "pipeline_group_#{vars[:pipeline_name]}_panel")
      |> find_all_within_element(:class, "setting")
      |> map(&(attribute_value(&1, "href")))
  end

  defp map_attributes(list, attribute_name) do
    Enum.map(list, fn(x) -> attribute_value(x, attribute_name) end)
  end

  defp scrape(url, files) do
    env_file = files[@env_filename]
    cmd_file = files[@cmd_filename]
    navigate_to(url)
    scrape_vars(env_file)
    find_element(:class, "stages")
      |> find_all_within_element(:tag, "a")
      |> map(&(attribute_value(&1, "href")))
      |> each(&(scrape_sub_stage(&1, env_file, cmd_file)))
  end

  defp scrape_sub_stages(urls, env_file, commands_file) do
    scrape_sub_stage(hd(urls), env_file, commands_file)
    if length(urls) > 1 do
      scrape_sub_stages(tl(urls), env_file, commands_file)
    end
  end

  defp scrape_sub_stage(url, env_file, commands_file) do
    navigate_to(url)
    scrape_tasks(commands_file)
    scrape_vars(env_file)
  end

  defp scrape_vars(file) do
    environment_vars_link = find_element(:id, "environment_variables", 0)
    environment_vars_a = find_within_element(environment_vars_link, :tag, "a")
    env_vars_href = attribute_value(environment_vars_a, "href")
    navigate_to(env_vars_href)
    stage_name = get_stage_name
    env_vars = get_vars(find_element(:id, "variables", 0))
    secure_vars = get_secure_vars
    env_vars = Enum.map(env_vars, fn(x) -> ",env," <> x end)
    secure_vars = Enum.map(secure_vars, fn(x) -> ",secure," <> x end)
    if length(env_vars) + length(secure_vars) > 0 do
      write_row([stage_name], file)
    end
    if length(env_vars) > 0 do
      write_row(env_vars, file)
    end
    if length(secure_vars) > 0 do
      write_row(secure_vars, file)
    end
  end

  defp get_vars(elem) do
    name_elems = find_all_within_element(elem, :class, "environment_variable_name", 0)
    val_elems = find_all_within_element(elem, :class, "environment_variable_value", 0)
    names = List.delete(map_attributes(name_elems, "value"), "")
    vals = List.delete(map_attributes(val_elems, "value"), "")
    merge(names, vals)
  end

  defp get_secure_vars do
    try do
      get_vars(find_element(:id, "variables_secure", 0))
    rescue
      RuntimeError -> "No secure variables found."
      []
    end
  end

  defp scrape_tasks(file) do
    rows = get_task_rows
    if (length(rows) > 0) do
      write_row([get_stage_name], file)
      tasks = get_tasks(rows)
      csvified_tasks = get_csvified_tasks(tasks)
      write_row(csvified_tasks, file)
    end
  end

  defp get_task_rows do
    try do
      container = find_element(:class, "tasks_list_table", 0)
      tbody = find_within_element(container, :tag, "tbody", 0)
      find_all_within_element(tbody, :tag, "tr", 0)
    rescue
      RuntimeError -> "No tasks found."
      []
    end
  end

  defp get_tasks([]) do
    []
  end

  defp get_tasks([head|tail]) do
    try do
      runif = visible_text(find_within_element(head, :class, "run_ifs", 0))
      properties = visible_text(find_within_element(head, :class, "properties", 0))
      task = "," <> runif <> properties
      formatted_task = String.replace(task, "\n", " ")
      [formatted_task|get_tasks(tail)]
    rescue
      RuntimeError -> "No task in this row."
      [""|get_tasks(tail)]
    end
  end

  defp get_csvified_tasks([]), do: []
  defp get_csvified_tasks([hd|tl]) do
    csvified_task = @cmd_fields |> map(&("#{&1}: ")) |> csvify(hd, ",")
    [csvified_task|get_csvified_tasks(tl)]
  end

  defp csvify([], string, seperators), do: string
  defp csvify([pattern|patterns_tl], string, seperators) do
    cond do
      String.contains?(string, pattern) ->
        csvify(patterns_tl, String.replace(string, pattern, seperators), ",")
      :else ->
        csvify(patterns_tl, string, seperators <> ",")
    end
  end

  defp write_row(task, file) when is_binary(task) do
    IO.binwrite(file, task <> "\n")
  end

  defp write_row([], file), do: :ok
  defp write_row(tasks, file) do
    IO.binwrite(file, hd(tasks) <> "\n")
    write_row(tl(tasks), file)
  end

  defp merge([names_hd|names_tl], [vals_hd|vals_tl]) do
    ["#{names_hd},#{vals_hd}"|merge(names_tl, vals_tl)]
  end

  defp merge([], []) do
    []
  end

  defp get_stage_name do
    visible_text(find_element(:class, "pipeline_header", 0))
  end
end
