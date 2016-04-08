defmodule Scraper do

  use Hound.Helpers

  def start do
    Hound.start_session
    {:ok, pipeline_name} = Application.fetch_env(:scraper, :go_pipeline_name)
    {:ok, username} = Application.fetch_env(:scraper, :go_username)
    {:ok, password} = Application.fetch_env(:scraper, :go_password)
    {:ok, base_url} = Application.fetch_env(:scraper, :go_base_url)
    login(username, password, base_url)
    reset_files
    links = get_stages_links(pipeline_name)
    {:ok, env_file} = File.open "env_variables.csv", [:append]
    {:ok, commands_file} = File.open "commands.csv", [:append]
    patterns = ["Command: ", "Arguments: ", "Working Directory: ", "Pipeline Name: ", "Stage Name: ", "Job Name: ", "Source Directory: ", "Destination: ", "Build File: ", "Target: "]
    titles = Enum.join(["", "Run if" | patterns], ",")
    write_row([titles], commands_file)
    scrape(links, patterns, env_file, commands_file)
    Hound.end_session
    File.close env_file
    File.close commands_file
  end

  def get_stages_links(pipeline_name) do
    pipeline = find_element(:id, "pipeline_group_#{pipeline_name}_panel", 0)
    settings_buttons = find_all_within_element(pipeline, :class, "setting", 0)
    get_attributes(settings_buttons, "href")
  end

  def scrape(urls, patterns, env_file, commands_file) do
    scrape_super_stage(hd(urls), patterns, env_file, commands_file)
    if length(urls) > 1 do
      scrape(tl(urls), patterns, env_file, commands_file)
    end
  end

  def scrape_super_stage(url, patterns, env_file, commands_file) do
    navigate_to(url)
    scrape_vars(env_file)
    container = find_element(:class, "stages", 0)
    sub_stage_links = find_all_within_element(container, :tag, "a", 0)
    sub_stage_urls = get_attributes(sub_stage_links, "href")
    scrape_sub_stages(sub_stage_urls, env_file, commands_file, patterns)
  end

  def scrape_sub_stages(urls, env_file, commands_file, patterns) do
    scrape_sub_stage(hd(urls), env_file, commands_file, patterns)
    if length(urls) > 1 do
      scrape_sub_stages(tl(urls), env_file, commands_file, patterns)
    end
  end

  def scrape_sub_stage(url, env_file, commands_file, patterns) do
    navigate_to(url)
    scrape_tasks(commands_file, patterns)
    scrape_vars(env_file)
  end

  def scrape_vars(file) do
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

  def get_vars(elem) do
    name_elems = find_all_within_element(elem, :class, "environment_variable_name", 0)
    val_elems = find_all_within_element(elem, :class, "environment_variable_value", 0)
    names = List.delete(get_attributes(name_elems, "value"), "")
    vals = List.delete(get_attributes(val_elems, "value"), "")
    merge(names, vals)
  end

  def get_secure_vars do
    try do
      get_vars(find_element(:id, "variables_secure", 0))
    rescue
      RuntimeError -> "No secure variables found."
      []
    end
  end

  def scrape_tasks(file, patterns) do
    rows = get_task_rows
    if (length(rows) > 0) do
      write_row([get_stage_name], file)
      tasks = get_tasks(rows)
      csvified_tasks = get_csvified_tasks(tasks, patterns)
      write_row(csvified_tasks, file)
    end
  end

  def get_task_rows do
    try do
      container = find_element(:class, "tasks_list_table", 0)
      tbody = find_within_element(container, :tag, "tbody", 0)
      find_all_within_element(tbody, :tag, "tr", 0)
    rescue
      RuntimeError -> "No tasks found."
      []
    end
  end

  def get_tasks([]) do
    []
  end

  def get_tasks([head|tail]) do
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

  def get_csvified_tasks([], patterns) do
    []
  end

  def get_csvified_tasks([head|tail], patterns) do
    csvified_task = csvify(head, patterns, ",")
    [csvified_task|get_csvified_tasks(tail, patterns)]
  end

  def csvify(task, [], to_insert) do
    task
  end

  def csvify(task, [pattern|tail], to_insert) do
    cond do
      String.contains?(task, pattern) ->
        csvify(String.replace(task, pattern, to_insert), tail, ",")
      true ->
        csvify(task, tail, to_insert <> ",")
    end
  end

  def write_row(tasks, file) when length(tasks) <= 1 do
    IO.binwrite(file, hd(tasks) <> "\n")
  end

  def write_row(tasks, file) do
    IO.binwrite(file, hd(tasks) <> "\n")
    write_row(tl(tasks), file)
  end

  def get_attributes(list, attribute_name) do
    Enum.map(list, fn(x) -> attribute_value(x, attribute_name) end)
  end

  def merge([names_hd|names_tl], [vals_hd|vals_tl]) do
    ["#{names_hd},#{vals_hd}"|merge(names_tl, vals_tl)]
  end

  def merge([], []) do
    []
  end

  def login(username, password, base_url) do
    string = navigate_to(base_url)
    find_element(:id, "user_login", 0) |> fill_field(username)
    element = find_element(:id, "user_password", 0)
    fill_field(element, password)
    submit_element(element)
  end

  def reset_files do
    File.rm "env_variables.csv"
    File.rm "commands.csv"
  end

  def get_stage_name do
    visible_text(find_element(:class, "pipeline_header", 0))
  end
end
