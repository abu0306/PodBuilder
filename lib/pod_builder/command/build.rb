require 'pod_builder/core'

module PodBuilder
  module Command
    class Build
      def self.call 
        Configuration.check_inited
        PodBuilder::prepare_basepath

        argument_pods = ARGV.dup

        unless argument_pods.count > 0 
          return -1
        end

        raise "\n\nPlease rename your Xcode installation path removing spaces, current `#{`xcode-select -p`.strip()}`\n".red if `xcode-select -p`.strip().include?(" ")

        Podfile.sanity_check()
        check_not_building_subspecs(argument_pods)

        puts "Loading Podfile".yellow

        install_update_repo = OPTIONS.fetch(:update_repos, true)
        installer, analyzer = Analyze.installer_at(PodBuilder::basepath, install_update_repo)

        all_buildable_items = Analyze.podfile_items(installer, analyzer)
        prebuilt_items = all_buildable_items.select { |x| x.is_prebuilt }
        buildable_items = all_buildable_items - prebuilt_items

        build_all = argument_pods.first == "*"
        if build_all
          argument_pods = all_buildable_items.map(&:root_name).uniq
        else
          argument_pods = Podfile::resolve_pod_names(argument_pods, all_buildable_items)
          deps = all_buildable_items.select { |t| argument_pods.include?(t.root_name) }.map(&:dependency_names).flatten.map { |t| t.split("/").first }
          argument_pods += deps
          argument_pods.uniq!
        end

        available_argument_pods = argument_pods.select { |x| all_buildable_items.map(&:root_name).include?(x) }     
        (argument_pods - available_argument_pods).each { |x|
          puts "'#{x}' not found, skipping".magenta
        }
        argument_pods = available_argument_pods.uniq
        
        prebuilt_pods_to_install = prebuilt_items.select { |x| argument_pods.include?(x.root_name) }

        Podfile.restore_podfile_clean(all_buildable_items)

        restore_file_error = Podfile.restore_file_sanity_check
  
        check_splitted_subspecs_are_static(all_buildable_items)
        check_pods_exists(argument_pods, all_buildable_items)

        pods_to_build = resolve_pods_to_build(argument_pods, buildable_items)
        buildable_items -= pods_to_build

        # We need to split pods to build in 3 groups
        # 1. subspecs: because the resulting .framework path is treated differently when added to Configuration.subspecs_to_split
        # 2. pods to build in release
        # 3. pods to build in debug

        check_not_building_development_pods(pods_to_build)

        pods_to_build_subspecs = pods_to_build.select { |x| x.is_subspec && Configuration.subspecs_to_split.include?(x.name) }

        # Remove dependencies from pods to build
        all_dependencies_name = pods_to_build.map(&:dependency_names).flatten.uniq
        pods_to_build.select! { |x| !all_dependencies_name.include?(x.name) }

        pods_to_build -= pods_to_build_subspecs
        pods_to_build_debug = pods_to_build.select { |x| x.build_configuration == "debug" }
        pods_to_build_release = pods_to_build - pods_to_build_debug

        check_dependencies_build_configurations(all_buildable_items)

        podfiles_items = pods_to_build_subspecs.map { |x| [x] }
        podfiles_items.push(pods_to_build_debug)
        podfiles_items.push(pods_to_build_release)   

        licenses = []
        
        podfiles_items.select { |x| x.count > 0 }.each do |podfile_items|
          build_configuration = podfile_items.map(&:build_configuration).uniq.first
          
          podfile_items = podfile_items.map { |t| t.recursive_dependencies(all_buildable_items) }.flatten.uniq
          podfile_content = Podfile.from_podfile_items(podfile_items, analyzer, build_configuration)
          
          licenses += Install.podfile(podfile_content, podfile_items, podfile_items.first.build_configuration)
          
          # remove lockfile which gets unexplicably created
          FileUtils.rm_f(PodBuilder::basepath("Podfile.lock"))
        end

        Clean::prebuilt_items(all_buildable_items)

        Licenses::write(licenses, all_buildable_items)

        GenerateLFS::call()
        Podspec::generate(all_buildable_items, analyzer)

        builded_pods = podfiles_items.flatten
        
        builded_pods_and_deps = podfiles_items.flatten.map { |t| t.recursive_dependencies(all_buildable_items) }.flatten.uniq
        builded_pods_and_deps.select! { |x| !x.is_prebuilt }
        
        Podfile::write_restorable(builded_pods_and_deps + prebuilt_pods_to_install, all_buildable_items, analyzer)     
        if !OPTIONS.has_key?(:skip_prebuild_update)   
          Podfile::write_prebuilt(all_buildable_items, analyzer)
        end

        Podfile::install

        sanity_checks

        if (restore_file_error = restore_file_error) && Configuration.restore_enabled
          puts "\n\n⚠️ Podfile.restore was found invalid and was overwritten. Error:\n #{restore_file_error}".red
        end

        puts "\n\n🎉 done!\n".green
        return 0
      end

      private

      def self.check_not_building_subspecs(pods_to_build)
        pods_to_build.each do |pod_to_build|
          if pod_to_build.include?("/")
            raise "\n\nCan't build subspec #{pod_to_build} refer to podspec name.\n\nUse `pod_builder build #{pods_to_build.map { |x| x.split("/").first }.uniq.join(" ")}` instead\n\n".red
          end
        end
      end

      def self.check_pods_exists(pods, buildable_items)
        raise "\n\nEmpty Podfile?".red if buildable_items.nil?

        buildable_items = buildable_items.map(&:root_name)
        pods.each do |pod|
          raise "\n\nPod `#{pod}` wasn't found in Podfile.\n\nFound:\n#{buildable_items.join("\n")}\n\n".red if !buildable_items.include?(pod)
        end
      end

      def self.check_splitted_subspecs_are_static(all_buildable_items)
        non_static_subspecs = all_buildable_items.select { |x| x.is_subspec && x.is_static == false }
        non_static_subspecs_names = non_static_subspecs.map(&:name)

        invalid_subspecs = Configuration.subspecs_to_split & non_static_subspecs_names # intersect

        unless invalid_subspecs.count > 0
          return
        end

        warn_message = "The following pods `#{invalid_subspecs.join(" ")}` are non static binaries which are being splitted over different targets. Beware that this is an unsafe setup as per https://github.com/CocoaPods/CocoaPods/issues/5708 and https://github.com/CocoaPods/CocoaPods/issues/5643\n\nYou can ignore this error by passing the `--allow-warnings` flag to the build command\n"
        if OPTIONS[:allow_warnings]
          puts "\n\n⚠️  #{warn_message}".yellow
        else
          raise "\n\n🚨️  #{warn_message}".red
        end
      end

      def self.check_dependencies_build_configurations(pods)
        pods.each do |pod|
          pod_dependency_names = pod.dependency_names.select { |x| !pod.has_common_spec(x) }

          remaining_pods = pods - [pod]
          pods_with_common_deps = remaining_pods.select { |x| x.dependency_names.any? { |y| pod_dependency_names.include?(y) && !x.has_common_spec(y) } }
          
          pods_with_unaligned_build_configuration = pods_with_common_deps.select { |x| x.build_configuration != pod.build_configuration }
          pods_with_unaligned_build_configuration.map!(&:name)

          raise "\n\nDependencies of `#{pod.name}` don't have the same build configuration (#{pod.build_configuration}) of `#{pods_with_unaligned_build_configuration.join(",")}`'s dependencies".red if pods_with_unaligned_build_configuration.count > 0
        end
      end

      def self.check_not_building_development_pods(pods)
        if (development_pods = pods.select { |x| x.is_development_pod }) && development_pods.count > 0 && (OPTIONS[:allow_warnings].nil?  && Configuration.allow_building_development_pods == false)
          pod_names = development_pods.map(&:name).join(", ")
          raise "\n\nThe following pods are in development mode: `#{pod_names}`, won't proceed building.\n\nYou can ignore this error by passing the `--allow-warnings` flag to the build command\n".red
        end
      end

      def self.other_subspecs(pods_to_build, buildable_items)
        buildable_subspecs = buildable_items.select { |x| x.is_subspec }
        pods_to_build_subspecs = pods_to_build.select { |x| x.is_subspec }.map(&:root_name)

        buildable_subspecs.select! { |x| pods_to_build_subspecs.include?(x.root_name) }

        return buildable_subspecs - pods_to_build
      end

      def self.sanity_checks
        lines = File.read(PodBuilder::project_path("Podfile")).split("\n")
        stripped_lines = lines.map { |x| Podfile.strip_line(x) }.select { |x| !x.start_with?("#")}

        expected_stripped = Podfile::POST_INSTALL_ACTIONS.map { |x| Podfile.strip_line(x) }

        if !expected_stripped.all? { |x| stripped_lines.include?(x) }
          warn_message = "PodBuilder's post install actions missing from application Podfile!\n"
          if OPTIONS[:allow_warnings]
            puts "\n\n⚠️  #{warn_message}".yellow
          else
            raise "\n\n🚨️  #{warn_message}".red
          end
        end
      end

      def self.resolve_pods_to_build(argument_pods, buildable_items)
        pods_to_build = []
        
        pods_to_build = buildable_items.select { |x| argument_pods.include?(x.root_name) }
        pods_to_build += other_subspecs(pods_to_build, buildable_items)

        return pods_to_build
      end      
    end
  end
end
