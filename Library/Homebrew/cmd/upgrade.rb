# typed: strict
# frozen_string_literal: true

require "abstract_command"
require "formula_installer"
require "install"
require "upgrade"
require "cask/utils"
require "cask/upgrade"
require "cask/macos"
require "api"

module Homebrew
  module Cmd
    class UpgradeCmd < AbstractCommand
      cmd_args do
        description <<~EOS
          Upgrade outdated casks and outdated, unpinned formulae using the same options they were originally
          installed with, plus any appended brew formula options. If <cask> or <formula> are specified,
          upgrade only the given <cask> or <formula> kegs (unless they are pinned; see `pin`, `unpin`).

          Unless `$HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK` is set, `brew upgrade` or `brew reinstall` will be run for
          outdated dependents and dependents with broken linkage, respectively.

          Unless `$HOMEBREW_NO_INSTALL_CLEANUP` is set, `brew cleanup` will then be run for the
          upgraded formulae or, every 30 days, for all formulae.
        EOS
        switch "-d", "--debug",
               description: "If brewing fails, open an interactive debugging session with access to IRB " \
                            "or a shell inside the temporary build directory."
        switch "--display-times",
               env:         :display_install_times,
               description: "Print install times for each package at the end of the run."
        switch "-f", "--force",
               description: "Install formulae without checking for previously installed keg-only or " \
                            "non-migrated versions. When installing casks, overwrite existing files " \
                            "(binaries and symlinks are excluded, unless originally from the same cask)."
        switch "-v", "--verbose",
               description: "Print the verification and post-install steps."
        switch "-n", "--dry-run",
               description: "Show what would be upgraded, but do not actually upgrade anything."
        [
          [:switch, "--formula", "--formulae", {
            description: "Treat all named arguments as formulae. If no named arguments " \
                         "are specified, upgrade only outdated formulae.",
          }],
          [:switch, "-s", "--build-from-source", {
            description: "Compile <formula> from source even if a bottle is available.",
          }],
          [:switch, "-i", "--interactive", {
            description: "Download and patch <formula>, then open a shell. This allows the user to " \
                         "run `./configure --help` and otherwise determine how to turn the software " \
                         "package into a Homebrew package.",
          }],
          [:switch, "--force-bottle", {
            description: "Install from a bottle if it exists for the current or newest version of " \
                         "macOS, even if it would not normally be used for installation.",
          }],
          [:switch, "--fetch-HEAD", {
            description: "Fetch the upstream repository to detect if the HEAD installation of the " \
                         "formula is outdated. Otherwise, the repository's HEAD will only be checked for " \
                         "updates when a new stable or development version has been released.",
          }],
          [:switch, "--keep-tmp", {
            description: "Retain the temporary files created during installation.",
          }],
          [:switch, "--debug-symbols", {
            depends_on:  "--build-from-source",
            description: "Generate debug symbols on build. Source will be retained in a cache directory.",
          }],
          [:switch, "--overwrite", {
            description: "Delete files that already exist in the prefix while linking.",
          }],
          [:switch, "--ask", {
            description: "Ask for confirmation before downloading and upgrading formulae. " \
              "Print bottles and dependencies download size, install and net install size.",
            env:         :ask,
          }],
        ].each do |args|
          options = args.pop
          send(*args, **options)
          conflicts "--cask", args.last
        end
        formula_options
        [
          [:switch, "--cask", "--casks", {
            description: "Treat all named arguments as casks. If no named arguments " \
                         "are specified, upgrade only outdated casks.",
          }],
          [:switch, "--skip-cask-deps", {
            description: "Skip installing cask dependencies.",
          }],
          [:switch, "-g", "--greedy", {
            description: "Also include casks with `auto_updates true` or `version :latest`.",
          }],
          [:switch, "--greedy-latest", {
            description: "Also include casks with `version :latest`.",
          }],
          [:switch, "--greedy-auto-updates", {
            description: "Also include casks with `auto_updates true`.",
          }],
          [:switch, "--[no-]binaries", {
            description: "Disable/enable linking of helper executables (default: enabled).",
            env:         :cask_opts_binaries,
          }],
          [:switch, "--require-sha",  {
            description: "Require all casks to have a checksum.",
            env:         :cask_opts_require_sha,
          }],
          [:switch, "--[no-]quarantine", {
            description: "Disable/enable quarantining of downloads (default: enabled).",
            env:         :cask_opts_quarantine,
          }],
        ].each do |args|
          options = args.pop
          send(*args, **options)
          conflicts "--formula", args.last
        end
        cask_options

        conflicts "--build-from-source", "--force-bottle"

        named_args [:installed_formula, :installed_cask]
      end

      sig { override.void }
      def run
        if args.build_from_source? && args.named.empty?
          raise ArgumentError, "--build-from-source requires at least one formula"
        end

        formulae, casks = args.named.to_resolved_formulae_to_casks
        # If one or more formulae are specified, but no casks were
        # specified, we want to make note of that so we don't
        # try to upgrade all outdated casks.
        only_upgrade_formulae = formulae.present? && casks.blank?
        only_upgrade_casks = casks.present? && formulae.blank?

        formulae = Homebrew::Attestation.sort_formulae_for_install(formulae) if Homebrew::Attestation.enabled?

        upgrade_outdated_formulae(formulae) unless only_upgrade_casks
        upgrade_outdated_casks(casks) unless only_upgrade_formulae

        Cleanup.periodic_clean!(dry_run: args.dry_run?)

        Homebrew.messages.display_messages(display_times: args.display_times?)
      end

      private

      sig { params(formulae: T::Array[Formula]).returns(T::Boolean) }
      def upgrade_outdated_formulae(formulae)
        return false if args.cask?

        if args.build_from_source?
          unless DevelopmentTools.installed?
            raise BuildFlagsError.new(["--build-from-source"], bottled: formulae.all?(&:bottled?))
          end

          unless Homebrew::EnvConfig.developer?
            opoo "building from source is not supported!"
            puts "You're on your own. Failures are expected so don't create any issues, please!"
          end
        end

        if formulae.blank?
          outdated = Formula.installed.select do |f|
            f.outdated?(fetch_head: args.fetch_HEAD?)
          end
        else
          outdated, not_outdated = formulae.partition do |f|
            f.outdated?(fetch_head: args.fetch_HEAD?)
          end

          not_outdated.each do |f|
            latest_keg = f.installed_kegs.max_by(&:scheme_and_version)
            if latest_keg.nil?
              ofail "#{f.full_specified_name} not installed"
            else
              opoo "#{f.full_specified_name} #{latest_keg.version} already installed" unless args.quiet?
            end
          end
        end

        return false if outdated.blank?

        pinned = outdated.select(&:pinned?)
        outdated -= pinned
        formulae_to_install = outdated.map do |f|
          f_latest = f.latest_formula
          if f_latest.latest_version_installed?
            f
          else
            f_latest
          end
        end

        if pinned.any?
          Kernel.public_send(
            formulae.any? ? :ofail : :opoo, # only fail when pinned formulae are named explicitly
            "Not upgrading #{pinned.count} pinned #{Utils.pluralize("package", pinned.count)}:",
          )
          puts pinned.map { |f| "#{f.full_specified_name} #{f.pkg_version}" } * ", "
        end

        if formulae_to_install.empty?
          oh1 "No packages to upgrade"
        else
          verb = args.dry_run? ? "Would upgrade" : "Upgrading"
          oh1 "#{verb} #{formulae_to_install.count} outdated #{Utils.pluralize("package",
                                                                               formulae_to_install.count)}:"
          formulae_upgrades = formulae_to_install.map do |f|
            if f.optlinked?
              "#{f.full_specified_name} #{Keg.new(f.opt_prefix).version} -> #{f.pkg_version}"
            else
              "#{f.full_specified_name} #{f.pkg_version}"
            end
          end
          puts formulae_upgrades.join("\n")
        end

        Install.perform_preinstall_checks_once

        ask_input = lambda {
          ohai "Do you want to proceed with the installation? [Y/y/yes/N/n]"
          accepted_inputs = %w[y yes]
          declined_inputs = %w[n no]
          loop do
            result = $stdin.gets.chomp.strip.downcase
            if accepted_inputs.include?(result)
              puts "Proceeding with installation..."
              break
            elsif declined_inputs.include?(result)
              return
            else
              puts "Invalid input. Please enter 'Y', 'y', or 'yes' to proceed, or 'N' to abort."
            end
          end
        }

        # Build a unique list of formulae to size by including:
        # 1. The original formulae to install.
        # 2. Their outdated dependents (subject to pruning criteria).
        # 3. Optionally, any installed formula that depends on one of these and is outdated.
        compute_sized_formulae = lambda { |formulae_to_install, check_dep: true|
          sized_formulae = formulae_to_install.flat_map do |formula|
            # Always include the formula itself.
            formula_list = [formula]

            # If there are dependencies, try to gather outdated, bottled ones.
            if formula.deps.any? && check_dep
              outdated_dependents = formula.recursive_dependencies do |_, dep|
                dep_formula = dep.to_formula
                next :prune if dep_formula.deps.empty?
                next :prune unless dep_formula.outdated?
                next :prune unless dep_formula.bottled?
              end.flatten

              # Convert each dependency to its formula.
              formula_list.concat(outdated_dependents.flat_map { |dep| Array(dep.to_formula) })
            end

            formula_list
          end

          # Add any installed formula that depends on one of the sized formulae and is outdated.
          unless Homebrew::EnvConfig.no_installed_dependents_check? || !check_dep
            installed_outdated = Formula.installed.select do |installed_formula|
              installed_formula.outdated? &&
                installed_formula.deps.any? { |dep| sized_formulae.include?(dep.to_formula) }
            end
            sized_formulae.concat(installed_outdated)
          end

          # Uniquify based on a string representation (or any unique identifier)
          sized_formulae.uniq { |f| f.to_s }
        }

        # Compute the total sizes (download, installed, and net) for the given formulae.
        compute_total_sizes = lambda { |sized_formulae, debug: false|
          total_download_size  = 0
          total_installed_size = 0
          total_net_size       = 0

          sized_formulae.each do |formula|
            next unless (bottle = formula.bottle)

            # Fetch additional bottle metadata (if necessary).
            bottle.fetch_tab(quiet: !debug)

            total_download_size  += bottle.bottle_size.to_i if bottle.bottle_size
            total_installed_size += bottle.installed_size.to_i if bottle.installed_size

            # Sum disk usage for all installed kegs of the formula.
            if formula.installed_kegs.any?
              kegs_dep_size = formula.installed_kegs.sum { |keg| keg.disk_usage.to_i }
              if bottle.installed_size
                total_net_size += bottle.installed_size.to_i - kegs_dep_size
              end
            end
          end

          { download: total_download_size,
            installed: total_installed_size,
            net: total_net_size }
        }

        # Main block: if asking the user is enabled, show dependency and size information.
        # This part should be
        if args.ask?
          ohai "Looking for bottles..."

          sized_formulae = compute_sized_formulae(formulae_to_install)
          sizes = compute_total_sizes(sized_formulae, debug: args.debug?)

          puts "Formulae: #{sized_formulae.join(", ")}\n\n"
          puts "Download Size: #{disk_usage_readable(sizes[:download])}"
          puts "Install Size:  #{disk_usage_readable(sizes[:installed])}"
          puts "Net Install Size: #{disk_usage_readable(sizes[:net])}" if sizes[:net] != 0

          ask_input.call
        end

        Upgrade.upgrade_formulae(
          formulae_to_install,
          flags:                      args.flags_only,
          dry_run:                    args.dry_run?,
          force_bottle:               args.force_bottle?,
          build_from_source_formulae: args.build_from_source_formulae,
          interactive:                args.interactive?,
          keep_tmp:                   args.keep_tmp?,
          debug_symbols:              args.debug_symbols?,
          force:                      args.force?,
          overwrite:                  args.overwrite?,
          debug:                      args.debug?,
          quiet:                      args.quiet?,
          verbose:                    args.verbose?,
        )

        Upgrade.check_installed_dependents(
          formulae_to_install,
          flags:                      args.flags_only,
          dry_run:                    args.dry_run?,
          force_bottle:               args.force_bottle?,
          build_from_source_formulae: args.build_from_source_formulae,
          interactive:                args.interactive?,
          keep_tmp:                   args.keep_tmp?,
          debug_symbols:              args.debug_symbols?,
          force:                      args.force?,
          debug:                      args.debug?,
          quiet:                      args.quiet?,
          verbose:                    args.verbose?,
        )

        true
      end

      sig { params(casks: T::Array[Cask::Cask]).returns(T::Boolean) }
      def upgrade_outdated_casks(casks)
        return false if args.formula?

        Cask::Upgrade.upgrade_casks(
          *casks,
          force:               args.force?,
          greedy:              args.greedy?,
          greedy_latest:       args.greedy_latest?,
          greedy_auto_updates: args.greedy_auto_updates?,
          dry_run:             args.dry_run?,
          binaries:            args.binaries?,
          quarantine:          args.quarantine?,
          require_sha:         args.require_sha?,
          skip_cask_deps:      args.skip_cask_deps?,
          verbose:             args.verbose?,
          quiet:               args.quiet?,
          args:,
        )
      end
    end
  end
end
