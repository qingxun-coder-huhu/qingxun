Rails.application.routes.draw do
  # 健康检查（容器/负载均衡探活用）
  get "up" => "rails/health#show", as: :rails_health_check

  # 开源版免登录：根路径直达脚本生成页
  root "scripts#index"

  # ---- 脚本生成 / 管理 / 版本 ----
  get 'scripts', to: 'scripts#index'
  # 首页「生成需求描述」用表单 POST 把目标与日志交过来（不落存储）
  post 'scripts', to: 'scripts#index'
  resources :scripts, only: [:destroy] do
    collection do
      get :my_scripts
      post :generate
      match :auto_generate, via: [:get, :post]
      post :suggest_branches
      post :check_branches
      # 单场景「运行」：按描述只生成命令映射并运行当前脚本（不改代码）
      post :run_scenario
      post :draft_requirement
      # 按真实执行日志 + 用户要求改进主线描述
      post :improve_description
      post :save
      post :debug_complete
      # 自动保存与版本历史（列表 / 单条详情 / 回滚）
      post :autosave
      get :versions
      get :version
      post :rollback
    end
  end

  # ---- 任务与设备 ----
  resources :tasks, only: [:index, :show, :new, :create, :edit, :update, :destroy] do
    collection do
      get :new_data
    end
    member do
      post :run
      get :status
      post :reset
      get :report
      get :report_data
      get :export_report
      get :edit_data
    end
  end

  # 设备型号：用户维护自己的型号清单，脚本生成页据此给候选
  resources :device_models, except: [:show, :new]

  # 设备管理（带连接凭据，用于真机执行）
  resources :network_elements, except: [:show] do
    collection do
      post :execute_batch
    end
    member do
      post :test_connection
      post :execute
    end
  end

  # 自定义集成
  resource :custom_integration, only: [:show, :update]

  # ---- 帮助页 ----
  get 'help', to: 'pages#help'
  get 'script_generation_help', to: 'pages#script_generation_help', as: :script_generation_help
  # 脚本开发全流程（从手工日志到调试完成的完整闭环）
  get 'guide', to: 'pages#guide', as: :guide
end
