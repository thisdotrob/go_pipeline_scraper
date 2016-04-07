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
    write_row(Enum.concat(["", "Run if"], patterns), commands_file)
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

  def scrape_tasks(file, patterns) do
    rows = get_task_rows
    if (length(rows) > 0) do
      write_row([get_stage_name], file)
      tasks = get_tasks(rows)
      csvified_tasks = get_csvified_tasks(tasks, patterns)
      write_tasks(csvified_tasks, file)
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
      task = ",#{runif} #{properties}"
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

  def csvify(task, [head|tail], to_insert) do
    pattern = head
    if (String.contains?(task, pattern)) do
      new_task = String.replace(task, pattern, to_insert)
      csvify(new_task, tail, ",")
    else
      csvify(task, tail, "#{to_insert},")
    end
  end

  def scrape_vars(file) do
    environment_vars_tab = find_element(:id, "environment_variables", 0)
    click(environment_vars_tab)
    stage_name = get_stage_name
    env_vars = get_env_vars(stage_name)
    secure_vars = get_secure_vars(stage_name)
    write_row(env_vars, file)
    write_row(secure_vars, file)
  end

  def get_env_vars(stage_name) do
    container = find_element(:id, "variables", 0)
    get_vars(container, stage_name)
  end

  def get_secure_vars(stage_name) do
    try do
      container = find_element(:id, "variables_secure", 0)
      get_vars(container, stage_name)
    rescue
      RuntimeError -> "No secure variables found."
      []
    end
  end

  def write_tasks(tasks, file) when length(tasks) <= 1 do
    IO.binwrite file, "#{hd(tasks)}\n"
  end

  def write_tasks(tasks, file) do
    IO.binwrite file, "#{hd(tasks)}\n"
    write_tasks(tl(tasks), file)
  end

  def write_row(strings, file) when length(strings) <= 1 do
    if length(strings) > 0 do
      IO.binwrite file, "#{hd(strings)}\n"
    end
  end

  def write_row(strings, file) do
    IO.binwrite file, "#{hd(strings)},"
    write_row(tl(strings), file)
  end

  def get_attributes([head|tail], attribute) do
    [attribute_value(head, attribute)|get_attributes(tail, attribute)]
  end

  def get_attributes([], attribute) do
    []
  end

  def get_vars(elem, stage_name) do
    name_elems = find_all_within_element(elem, :class, "environment_variable_name", 0)
    val_elems = find_all_within_element(elem, :class, "environment_variable_value", 0)
    names = List.delete(get_attributes(name_elems, "value"), "")
    vals = List.delete(get_attributes(val_elems, "value"), "")
    merged = merge(names, vals)
    prepend(merged, stage_name)
  end

  def prepend([head|tail], stage_name) do
    ["#{stage_name},#{head}"|prepend(tail, stage_name)]
  end

  def prepend([], stage_name) do
    []
  end

  def merge([names_hd|names_tl], [vals_hd|vals_tl]) do
    ["#{names_hd}=#{vals_hd}"|merge(names_tl, vals_tl)]
  end

  def merge([], []) do
    []
  end

  def login(username, password, base_url) do
    string = navigate_to(base_url)
    IO.puts "#{string}"
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
