defmodule Scraper do
  import Application, only: [fetch_env!: 2]
  import Enum, only: [each: 2, map: 2, join: 2, into: 2]
  import Map, only: [drop: 2]
  import List, only: [delete: 2]

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
    files = [@env_filename, @cmd_filename] |> get_reset_files
    files |> write_headers
    get_running_system_vars |> get_stages_links |> each(&scrape(&1, files))
    files |> each(&(File.close(&1)))
    Hound.end_session
  end

  defp get_reset_files(filenames) do
    filenames |> each(&(File.rm(&1)))

    create_opened_file_tuple = fn(filename) ->
      {filename, File.open!(filename, [:append])}
    end

    filenames |> map(&(create_opened_file_tuple.(&1))) |> into(%{})
  end

  defp write_headers(files) do
    [""|@env_fields] |> join(",") |> write_row(files[@env_filename])
    [",Run if"|@cmd_fields] |> join(",") |> write_row(files[@cmd_filename])
  end

  defp get_running_system_vars do
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
    drop(vars, [:pipeline_name]) |> login
    find_element(:id, "pipeline_group_#{vars[:pipeline_name]}_panel")
      |> find_all_within_element(:class, "setting")
      |> map(&(attribute_value(&1, "href")))
  end

  defp scrape(url, files) do
    env_file = files[@env_filename]
    cmd_file = files[@cmd_filename]
    navigate_to(url)
    scrape_and_write_vars(env_file)
    find_element(:class, "stages")
      |> find_all_within_element(:tag, "a")
      |> map(&(attribute_value(&1, "href")))
      |> each(&(scrape_sub_stage(&1, env_file, cmd_file)))
  end

  defp scrape_sub_stage(url, env_file, cmd_file) do
    navigate_to(url)
    scrape_tasks(cmd_file)
    scrape_and_write_vars(env_file)
  end

  defp scrape_tasks(cmd_file) do
    try do
      find_element(:class, "tasks_list_table")
        |> find_within_element(:tag, "tbody")
        |> find_all_within_element(:tag, "tr")
        |> get_tasks
        |> get_csvified_tasks
        |> write_row(cmd_file)
    rescue
      e in RuntimeError -> IO.puts(e.message)
    end
  end

  defp scrape_and_write_vars(file) do
    find_element(:id, "environment_variables")
      |> find_within_element(:tag, "a")
      |> attribute_value("href")
      |> navigate_to
    env_vars = extract_vars("variables") |> map(&(",env," <> &1))
    secure_vars = extract_vars("variables_secure") |> map(&(",secure," <> &1))
    var_count = length(env_vars) + length(secure_vars)
    if var_count > 0, do: write_row([get_stage_name], file)
    if length(env_vars) > 0, do: write_row(env_vars, file)
    if length(secure_vars) > 0, do: write_row(secure_vars, file)
  end

  defp extract_vars(elem_name) do
    extract = fn(class_name) ->
      find_element(:id, elem_name)
      |> find_all_within_element(:class, class_name)
      |> map(&(attribute_value(&1, "value")))
      |> delete("")
    end
    try do
      names = "environment_variable_name" |> extract.()
      vals = "environment_variable_value" |> extract.()
      merge(names, vals)
    rescue
      e in RuntimeError -> IO.puts(e.message)
      []
    end
  end

  defp get_tasks([]), do: []
  defp get_tasks([head|tail]) do
    try do
      runif = find_within_element(head, :class, "run_ifs") |> visible_text
      props = head |> find_within_element(:class, "properties") |> visible_text
      task = "," <> runif <> props
      formatted_task = String.replace(task, "\n", " ")
      [formatted_task|get_tasks(tail)]
    rescue
      e in RuntimeError -> IO.puts(e.message)
      [""|get_tasks(tail)]
    end
  end

  defp get_csvified_tasks([]), do: []
  defp get_csvified_tasks([hd|tl]) do
    csvified_task = @cmd_fields |> map(&("#{&1}: ")) |> csvify(hd, ",")
    [csvified_task|get_csvified_tasks(tl)]
  end

  defp csvify([], string, _), do: string
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

  defp write_row([], _), do: :ok
  defp write_row(tasks, file) do
    IO.binwrite(file, hd(tasks) <> "\n")
    write_row(tl(tasks), file)
  end

  defp merge([], []), do: []
  defp merge([names_hd|names_tl], [vals_hd|vals_tl]) do
    ["#{names_hd},#{vals_hd}" | merge(names_tl, vals_tl)]
  end

  defp get_stage_name do
    visible_text(find_element(:class, "pipeline_header", 0))
  end
end
