/*
 * Copyright (C) 2009-2015 Canonical Ltd.
 * Author: Robert Ancell <robert.ancell@canonical.com>
 *
 * This program is free software: you can redistribute it and/or modify it under
 * the terms of the GNU General Public License as published by the Free Software
 * Foundation, either version 3 of the License, or (at your option) any later
 * version. See http://www.gnu.org/copyleft/gpl.html the full text of the
 * license.
 */

/* TODO: Could indicate the start of the next page immediately after the last page is received (i.e. before the sane_cancel()) */

public class ScanDevice : Object
{
    public string name;
    public string label;
}

public class ScanPageInfo : Object
{
    /* Width, height in pixels */
    public int width;
    public int height;

    /* Bit depth */
    public int depth;

    /* Number of colour channels */
    public int n_channels;

    /* Resolution */
    public double dpi;

    /* The device this page came from */
    public string device;
}

public class ScanLine : Object
{
    /* Line number */
    public int number;

    /* Number of lines in this packet */
    public int n_lines;

    /* Width in pixels and format */
    public int width;
    public int depth;

    /* Channel for this line or -1 for all channels */
    public int channel;

    /* Raw line data */
    public uchar[] data;
    public int data_length;
}

public enum ScanMode
{
    DEFAULT,
    COLOR,
    GRAY,
    LINEART
}

public enum ScanType
{
    SINGLE,
    ADF,
    BATCH
}

public enum ScanSide
{
    FRONT,
    BACK,
    BOTH
}

public class ScanOptions : Object
{
    public int dpi;
    public ScanMode scan_mode;
    public int depth;
    public ScanType type;
    public ScanSide side;
    public int paper_width;
    public int paper_height;
    public int brightness;
    public int contrast;
    public int page_delay;
}

private class ScanJob : Object
{
    public int id;
    public string device;
    public double dpi;
    public ScanMode scan_mode;
    public int depth;
    public ScanType type;
    public ScanSide side;
    public int page_width;
    public int page_height;
    public int brightness;
    public int contrast;
    public int page_delay;
}

private class Request {}

private class RequestRedetect : Request {}

private class RequestCancel : Request {}

private class RequestStartScan : Request
{
    public ScanJob job;
}

private class RequestQuit : Request {}

private class Credentials
{
    public string username;
    public string password;
}

private enum ScanState
{
    IDLE = 0,
    REDETECT,
    OPEN,
    GET_OPTION,
    START,
    GET_PARAMETERS,
    READ
}

private class Notify
{
    public virtual void run (Scanner scanner) {}
}

private class NotifyScanningChanged : Notify
{
    public override void run (Scanner scanner) { scanner.scanning_changed (); }
}

private class NotifyUpdateDevices : Notify
{
    public NotifyUpdateDevices (owned List<ScanDevice> devices) { this.devices = (owned) devices; }
    private List<ScanDevice> devices;
    public override void run (Scanner scanner) { scanner.update_devices (devices); }
}

private class NotifyRequestAuthorization : Notify
{
    public NotifyRequestAuthorization (string resource) { this.resource = resource; }
    private string resource;
    public override void run (Scanner scanner) { scanner.request_authorization (resource); }
}

private class NotifyScanFailed : Notify
{
    public NotifyScanFailed (int error_code, string error_string) { this.error_code = error_code; this.error_string = error_string; }
    private int error_code;
    private string error_string;
    public override void run (Scanner scanner) { scanner.scan_failed (error_code, error_string); }
}

private class NotifyDocumentDone : Notify
{
    public override void run (Scanner scanner) { scanner.document_done (); }
}

private class NotifyExpectPage : Notify
{
    public override void run (Scanner scanner) { scanner.expect_page (); }
}

private class NotifyGotPageInfo : Notify
{
    public NotifyGotPageInfo (int job_id, ScanPageInfo info) { this.job_id = job_id; this.info = info; }
    private int job_id;
    private ScanPageInfo info;
    public override void run (Scanner scanner)
    {
        if (job_id >= scanner.first_job_id && job_id < scanner.job_id)
            scanner.got_page_info (info);
    }
}

private class NotifyPageDone : Notify
{
    public NotifyPageDone (int job_id) { this.job_id = job_id; }
    private int job_id;
    public override void run (Scanner scanner)
    {
        if (job_id >= scanner.first_job_id && job_id < scanner.job_id)
            scanner.page_done ();
    }
}

private class NotifyGotLine : Notify
{
    public NotifyGotLine (int job_id, ScanLine line) { this.job_id = job_id; this.line = line; }
    private int job_id;
    private ScanLine line;
    public override void run (Scanner scanner)
    {
        if (job_id >= scanner.first_job_id && job_id < scanner.job_id)
            scanner.got_line (line);
    }
}

public class Scanner : Object
{
    /* Singleton object */
    private static Scanner scanner_object = null;

    /* Thread communicating with SANE */
    private Thread<void*> thread;

    /* Queue of requests from main thread */
    private AsyncQueue<Request> request_queue;

    /* Queue of events to notify in main queue */
    private AsyncQueue<Notify> notify_queue;

    /* Queue of responses to authorization requests */
    private AsyncQueue<Credentials> authorize_queue;

    /* ID for the current job */
    public int first_job_id;
    public int job_id;

    private string? default_device;

    private ScanState state;
    private bool need_redetect;

    private List<ScanJob> job_queue;

    /* Handle to SANE device */
    private Sane.Handle handle;
    private bool have_handle;
    private string? current_device;

    private Sane.Parameters parameters;

    /* Last option read */
    private Sane.Int option_index;

    /* Table of options */
    private HashTable<string, int> options;

    /* Buffer for received line */
    private uchar[] buffer;
    private int n_used;

    //private int bytes_remaining;
    private int line_count;
    private int pass_number;
    private int page_number;
    private int notified_page;

    private bool scanning;

    public signal void update_devices (List<ScanDevice> devices);
    public signal void request_authorization (string resource);
    public signal void expect_page ();
    public signal void got_page_info (ScanPageInfo info);
    public signal void got_line (ScanLine line);
    public signal void scan_failed (int error_code, string error_string);
    public signal void page_done ();
    public signal void document_done ();
    public signal void scanning_changed ();

    private Scanner ()
    {
        request_queue = new AsyncQueue<Request> ();
        notify_queue = new AsyncQueue<Notify> ();
        authorize_queue = new AsyncQueue<Credentials> ();
    }

    public static Scanner get_instance ()
    {
        if (scanner_object == null)
            scanner_object = new Scanner ();
        return scanner_object;
    }

    private bool notify_idle_cb ()
    {
        var notification = notify_queue.pop ();
        notification.run (this);
        return false;
    }

    private void notify_event (Notify notification)
    {
        notify_queue.push (notification);
        Idle.add (notify_idle_cb);
    }

    private void set_scanning (bool is_scanning)
    {
        if ((scanning && !is_scanning) || (!scanning && is_scanning))
        {
            scanning = is_scanning;
            notify_event (new NotifyScanningChanged ());
        }
    }

    private static int get_device_weight (string device)
    {
        /* NOTE: This is using trends in the naming of SANE devices, SANE should be able to provide this information better */

        /* Use webcams as a last resort */
        if (device.has_prefix ("vfl:"))
           return 2;

        /* Use locally connected devices first */
        if (device.contains ("usb"))
           return 0;

        return 1;
    }

    private static int compare_devices (ScanDevice device1, ScanDevice device2)
    {
        /* TODO: Should do some fuzzy matching on the last selected device and set that to the default */

        var weight1 = get_device_weight (device1.name);
        var weight2 = get_device_weight (device2.name);
        if (weight1 != weight2)
            return weight1 - weight2;

        return strcmp (device1.label, device2.label);
    }

    private void do_redetect ()
    {
        unowned Sane.Device[] device_list = null;
        var status = Sane.get_devices (out device_list, false);
        debug ("sane_get_devices () -> %s", Sane.status_to_string (status));
        if (status != Sane.Status.GOOD)
        {
            warning ("Unable to get SANE devices: %s", Sane.strstatus(status));
            need_redetect = false;
            state = ScanState.IDLE;
            return;
        }

        /* Determine the number of each model to additionally display the name if the model names are the same. */
        var seen = new HashTable<string, int> (str_hash, str_equal);
        for (var i = 0; device_list[i] != null; i++)
        {
            if (seen.contains(device_list[i].model))
                seen.set(device_list[i].model, seen.get(device_list[i].model) + 1);
            else
                seen.set(device_list[i].model, 1);
        }

        var devices = new List<ScanDevice> ();
        for (var i = 0; device_list[i] != null; i++)
        {
            /* Virtual devices tend to not be scanners. Skip them. */
            if (device_list[i].type == "virtual device")
                continue;

            debug ("Device: name=\"%s\" vendor=\"%s\" model=\"%s\" type=\"%s\"",
                   device_list[i].name, device_list[i].vendor, device_list[i].model, device_list[i].type);

            var scan_device = new ScanDevice ();
            scan_device.name = device_list[i].name;

            /* Abbreviate HP as it is a long string and does not match what is on the physical scanner */
            var vendor = device_list[i].vendor;
            if (vendor == "Hewlett-Packard")
                vendor = "HP";

            /* Don't repeat vendor name */
            if (device_list[i].model.down().has_prefix (vendor.down()))
                scan_device.label = device_list[i].model;
            else
                scan_device.label = "%s %s".printf (vendor, device_list[i].model);
            
            /* Replace underscores in name */
            scan_device.label = scan_device.label.replace ("_", " ");
            
            /* Additionally add the device name to the label if there are several identical models. */
            if (seen.get(device_list[i].model) > 1)
                scan_device.label = "%s on %s".printf (scan_device.label, device_list[i].name);


            devices.append (scan_device);
        }

        /* Sort devices by priority */
        devices.sort (compare_devices);

        need_redetect = false;
        state = ScanState.IDLE;

        if (devices != null)
        {
            var device = devices.nth_data (0);
            default_device = device.name;
        }
        else
            default_device = null;

        notify_event (new NotifyUpdateDevices ((owned) devices));
    }

    private double scale_fixed (int source_min, int source_max, Sane.OptionDescriptor option, int value)
    {
        var v = (double) value;

        return_val_if_fail (option.type == Sane.ValueType.FIXED, value);
        if (option.constraint_type == Sane.ConstraintType.RANGE && option.range.max != option.range.min)
        {
            v -= (double) source_min;
            v *= Sane.UNFIX (option.range.max) - Sane.UNFIX (option.range.min);
            v /= (double) (source_max - source_min);
            v += Sane.UNFIX (option.range.min);
            debug ("scale_fixed: scaling %d [min: %d, max: %d] to %f [min: %f, max: %f]",
                   value, source_min, source_max, v, Sane.UNFIX (option.range.min), Sane.UNFIX (option.range.max));
        }

        return v;
    }

    private int scale_int (int source_min, int source_max, Sane.OptionDescriptor option, int value)
    {
        var v = value;

        return_val_if_fail (option.type == Sane.ValueType.INT, value);

        if (option.constraint_type == Sane.ConstraintType.RANGE && option.range.max != option.range.min)
        {
            v -= source_min;
            v *= (int) (option.range.max - option.range.min);
            v /= (source_max - source_min);
            v += (int) option.range.min;
            debug ("scale_int: scaling %d [min: %d, max: %d] to %d [min: %d, max: %d]",
                   value, source_min, source_max, v, (int) option.range.min, (int) option.range.max);
        }

        return v;
    }

    private bool set_default_option (Sane.Handle handle, Sane.OptionDescriptor option, Sane.Int option_index)
    {
        /* Check if supports automatic option */
        if ((option.cap & Sane.Capability.AUTOMATIC) == 0)
            return false;

        var status = Sane.control_option (handle, option_index, Sane.Action.SET_AUTO, null, null);
        debug ("sane_control_option (%d, SANE_ACTION_SET_AUTO, %s=auto) -> %s", (int) option_index, option.name, Sane.status_to_string (status));
        if (status != Sane.Status.GOOD)
            warning ("Error setting default option %s: %s", option.name, Sane.strstatus(status));

        return status == Sane.Status.GOOD;
    }

    private void set_bool_option (Sane.Handle handle, Sane.OptionDescriptor option, Sane.Int option_index, bool value, out bool result)
    {
        return_if_fail (option.type == Sane.ValueType.BOOL);

        Sane.Bool v = (Sane.Bool) value;
        var status = Sane.control_option (handle, option_index, Sane.Action.SET_VALUE, &v, null);
        result = (bool) v;
        debug ("sane_control_option (%d, SANE_ACTION_SET_VALUE, %s=%s) -> (%s, %s)", (int) option_index, option.name, value ? "SANE_TRUE" : "SANE_FALSE", Sane.status_to_string (status), result ? "SANE_TRUE" : "SANE_FALSE");
    }

    private void set_int_option (Sane.Handle handle, Sane.OptionDescriptor option, Sane.Int option_index, int value, out int result)
    {
        return_if_fail (option.type == Sane.ValueType.INT);

        Sane.Int v = (Sane.Int) value;
        if (option.constraint_type == Sane.ConstraintType.RANGE)
        {
            if (option.range.quant != 0)
                v *= option.range.quant;
            if (v < option.range.min)
                v = option.range.min;
            if (v > option.range.max)
                v = option.range.max;
        }
        else if (option.constraint_type == Sane.ConstraintType.WORD_LIST)
        {
            int distance = int.MAX, nearest = 0;

            /* Find nearest value to requested */
            for (var i = 0; i < option.word_list[0]; i++)
            {
                var x = (int) option.word_list[i+1];
                var d = (int) (x - v);
                d = d.abs ();
                if (d < distance)
                {
                    distance = d;
                    nearest = x;
                }
            }
            v = (Sane.Int) nearest;
        }

        var status = Sane.control_option (handle, option_index, Sane.Action.SET_VALUE, &v, null);
        debug ("sane_control_option (%d, SANE_ACTION_SET_VALUE, %s=%d) -> (%s, %d)", (int) option_index, option.name, value, Sane.status_to_string (status), (int) v);
        result = (int) v;
    }

    private void set_fixed_option (Sane.Handle handle, Sane.OptionDescriptor option, Sane.Int option_index, double value, out double result)
    {
        double v = value;
        Sane.Fixed v_fixed;

        return_if_fail (option.type == Sane.ValueType.FIXED);

        if (option.constraint_type == Sane.ConstraintType.RANGE)
        {
            double min = Sane.UNFIX (option.range.min);
            double max = Sane.UNFIX (option.range.max);

            if (v < min)
                v = min;
            if (v > max)
                v = max;
        }
        else if (option.constraint_type == Sane.ConstraintType.WORD_LIST)
        {
            double distance = double.MAX, nearest = 0.0;

            /* Find nearest value to requested */
            for (var i = 0; i < option.word_list[0]; i++)
            {
                double x = Sane.UNFIX (option.word_list[i+1]);
                if (Math.fabs (x - v) < distance)
                {
                    distance = Math.fabs (x - v);
                    nearest = x;
                }
            }
            v = nearest;
        }

        v_fixed = Sane.FIX (v);
        var status = Sane.control_option (handle, option_index, Sane.Action.SET_VALUE, &v_fixed, null);
        debug ("sane_control_option (%d, SANE_ACTION_SET_VALUE, %s=%f) -> (%s, %f)", (int) option_index, option.name, value, Sane.status_to_string (status), Sane.UNFIX (v_fixed));

        result = Sane.UNFIX (v_fixed);
    }

    private void set_fixed_or_int_option (Sane.Handle handle, Sane.OptionDescriptor option, Sane.Int option_index, double value, out double result)
    {
        if (option.type == Sane.ValueType.FIXED)
            set_fixed_option (handle, option, option_index, value, out result);
        else if (option.type == Sane.ValueType.INT)
        {
            int r;
            set_int_option (handle, option, option_index, (int) Math.round (value), out r);
            result = r;
        }
        else
        {
            result = 0.0;
            warning ("Unable to set unsupported option type");
        }
    }

    private void set_option_to_max (Sane.Handle handle, Sane.OptionDescriptor option, Sane.Int option_index)
    {
        if (option.constraint_type != Sane.ConstraintType.RANGE)
            return;

        var status = Sane.control_option (handle, option_index, Sane.Action.SET_VALUE, &option.range.max, null);

        if (option.type == Sane.ValueType.FIXED)
            debug ("sane_control_option (%d, SANE_ACTION_SET_VALUE, %s=option.range.max=%f) -> (%s)", (int) option_index, option.name, Sane.UNFIX (option.range.max), Sane.status_to_string (status));
        else
            debug ("sane_control_option (%d, SANE_ACTION_SET_VALUE, %s=option.range.max=%d) -> (%s)", (int) option_index, option.name, (int) option.range.max, Sane.status_to_string (status));
    }

    private bool set_string_option (Sane.Handle handle, Sane.OptionDescriptor option, Sane.Int option_index, string value, out string result)
    {
        result = "";

        return_val_if_fail (option.type == Sane.ValueType.STRING, false);

        var s = new char[option.size];
        var i = 0;
        for (; i < (option.size - 1) && value[i] != '\0'; i++)
            s[i] = value[i];
        s[i] = '\0';
        var status = Sane.control_option (handle, option_index, Sane.Action.SET_VALUE, s, null);
        result = (string) s;
        debug ("sane_control_option (%d, SANE_ACTION_SET_VALUE, %s=\"%s\") -> (%s, \"%s\")", (int) option_index, option.name, value, Sane.status_to_string (status), result);

        return status == Sane.Status.GOOD;
    }

    private bool set_constrained_string_option (Sane.Handle handle, Sane.OptionDescriptor option, Sane.Int option_index, string[] values, out string result)
    {
        return_val_if_fail (option.type == Sane.ValueType.STRING, false);
        return_val_if_fail (option.constraint_type == Sane.ConstraintType.STRING_LIST, false);

        for (var i = 0; values[i] != null; i++)
        {
            var j = 0;
            for (; option.string_list[j] != null; j++)
            {
                if (values[i] == option.string_list[j])
                   break;
            }

            if (option.string_list[j] != null)
                return set_string_option (handle, option, option_index, values[i], out result);
        }

        result = "";
        return false;
    }

    private bool set_int_array_option (Sane.Handle handle, Sane.OptionDescriptor option, Sane.Int option_index, double [] values)
    {
        return_val_if_fail (option.type == Sane.ValueType.INT, false);

        var optlen = option.size / sizeof (Sane.Word);
        var optval = new Sane.Word[optlen];
        for (var i = 0; i < optlen; i++)
            optval[i] = (Sane.Word) (values[i] + 0.5);

        var status = Sane.control_option (handle, option_index, Sane.Action.SET_VALUE, optval, null);
        return status == Sane.Status.GOOD;
    }

    private void log_option (Sane.Int index, Sane.OptionDescriptor option)
    {
        var s = "Option %d:".printf ((int) index);

        if (option.name != "")
            s += " name='%s'".printf (option.name);

        if (option.title != "")
            s += " title='%s'".printf (option.title);

        switch (option.type)
        {
        case Sane.ValueType.BOOL:
            s += " type=bool";
            break;
        case Sane.ValueType.INT:
            s += " type=int";
            break;
        case Sane.ValueType.FIXED:
            s += " type=fixed";
            break;
        case Sane.ValueType.STRING:
            s += " type=string";
            break;
        case Sane.ValueType.BUTTON:
            s += " type=button";
            break;
        case Sane.ValueType.GROUP:
            s += " type=group";
            break;
        default:
            s += " type=%d".printf (option.type);
            break;
        }

        s += " size=%d".printf ((int) option.size);

        switch (option.unit)
        {
        case Sane.Unit.NONE:
            break;
        case Sane.Unit.PIXEL:
            s += " unit=pixels";
            break;
        case Sane.Unit.BIT:
            s += " unit=bits";
            break;
        case Sane.Unit.MM:
            s += " unit=mm";
            break;
        case Sane.Unit.DPI:
            s += " unit=dpi";
            break;
        case Sane.Unit.PERCENT:
            s += " unit=percent";
            break;
        case Sane.Unit.MICROSECOND:
            s += " unit=microseconds";
            break;
        default:
            s += " unit=%d".printf (option.unit);
            break;
        }

        switch (option.constraint_type)
        {
        case Sane.ConstraintType.RANGE:
            if (option.range != null) {
                if (option.type == Sane.ValueType.FIXED)
                    s += " min=%f, max=%f, quant=%d".printf (Sane.UNFIX (option.range.min), Sane.UNFIX (option.range.max), (int) option.range.quant);
                else
                    s += " min=%d, max=%d, quant=%d".printf ((int) option.range.min, (int) option.range.max, (int) option.range.quant);
            }
            break;
        case Sane.ConstraintType.WORD_LIST:
            s += " values=[";
            for (var i = 0; i < option.word_list[0]; i++)
            {
                if (i != 0)
                    s += ", ";
                if (option.type == Sane.ValueType.INT)
                    s += "%d".printf ((int) option.word_list[i+1]);
                else
                    s += "%f".printf (Sane.UNFIX (option.word_list[i+1]));
            }
            s += "]";
            break;
        case Sane.ConstraintType.STRING_LIST:
            s += " values=[";
            if (option.string_list != null) {
                for (var i = 0; option.string_list[i] != null; i++)
                {
                    if (i != 0)
                        s += ", ";
                        s += "\"%s\"".printf (option.string_list[i]);
                }
            }
            s += "]";
            break;
        default:
            break;
        }

        var cap = option.cap;
        if (cap != 0)
        {
            var caps = "";
            if ((cap & Sane.Capability.SOFT_SELECT) != 0)
            {
                if (caps != "")
                    caps += ",";
                caps += "soft-select";
                cap &= ~Sane.Capability.SOFT_SELECT;
            }
            if ((cap & Sane.Capability.HARD_SELECT) != 0)
            {
                if (caps != "")
                    caps += ",";
                caps += "hard-select";
                cap &= ~Sane.Capability.HARD_SELECT;
            }
            if ((cap & Sane.Capability.SOFT_DETECT) != 0)
            {
                if (caps != "")
                    caps += ",";
                caps += "soft-detect";
                cap &= ~Sane.Capability.SOFT_DETECT;
            }
            if ((cap & Sane.Capability.EMULATED) != 0)
            {
                if (caps != "")
                    caps += ",";
                caps += "emulated";
                cap &= ~Sane.Capability.EMULATED;
            }
            if ((cap & Sane.Capability.AUTOMATIC) != 0)
            {
                if (caps != "")
                    caps += ",";
                caps += "automatic";
                cap &= ~Sane.Capability.AUTOMATIC;
            }
            if ((cap & Sane.Capability.INACTIVE) != 0)
            {
                if (caps != "")
                    caps += ",";
                caps += "inactive";
                cap &= ~Sane.Capability.INACTIVE;
            }
            if ((cap & Sane.Capability.ADVANCED) != 0)
            {
                if (caps != "")
                    caps += ",";
                caps += "advanced";
                cap &= ~Sane.Capability.ADVANCED;
            }
            /* Unknown capabilities */
            if (cap != 0)
            {
                if (caps != "")
                    caps += ",";
                caps += "%x".printf ((int) cap);
            }
            s += " cap=" + caps;
        }

        debug ("%s", s);

        if (option.desc != null)
            debug ("  Description: %s", option.desc);
    }

    private static void authorization_cb (string resource, char[] username, char[] password)
    {
        scanner_object.notify_event (new NotifyRequestAuthorization (resource));

        var credentials = scanner_object.authorize_queue.pop ();
        for (var i = 0; credentials.username[i] != '\0' && i < Sane.MAX_USERNAME_LEN; i++)
            username[i] = credentials.username[i];
        for (var i = 0; credentials.password[i] != '\0' && i < Sane.MAX_PASSWORD_LEN; i++)
            password[i] = credentials.password[i];
    }

    public void authorize (string username, string password)
    {
        var credentials = new Credentials ();
        credentials.username = username;
        credentials.password = password;
        authorize_queue.push (credentials);
    }

    private void close_device ()
    {
        if (have_handle)
        {
            Sane.cancel (handle);
            debug ("sane_cancel ()");

            Sane.close (handle);
            debug ("sane_close ()");
            have_handle = false;
            options = null;
        }

        buffer = null;
        job_queue = null;

        set_scanning (false);
    }

    private void fail_scan (int error_code, string error_string)
    {
        close_device ();
        state = ScanState.IDLE;
        notify_event (new NotifyScanFailed (error_code, error_string));
    }

    private bool handle_requests ()
    {
        /* Redetect when idle */
        if (state == ScanState.IDLE && need_redetect)
            state = ScanState.REDETECT;

        /* Process all requests */
        int request_count = 0;
        while (true)
        {
            Request request;
            if ((state == ScanState.IDLE && request_count == 0) ||
                request_queue.length () > 0)
                request = request_queue.pop ();
            else
                return true;

            debug ("Processing request");
            request_count++;

            if (request is RequestStartScan)
            {
                var r = (RequestStartScan) request;
                job_queue.append (r.job);
            }
            else if (request is RequestCancel)
            {
                fail_scan (Sane.Status.CANCELLED, "Scan cancelled - do not report this error");
            }
            else if (request is RequestQuit)
            {
                close_device ();
                return false;
            }
        }
    }

    private void do_open ()
    {
        var job = (ScanJob) job_queue.data;

        line_count = 0;
        pass_number = 0;
        page_number = 0;
        notified_page = -1;
        option_index = 0;

        if (job.device == null && default_device != null)
            job.device = default_device;

        if (job.device == null)
        {
            warning ("No scan device available");
            fail_scan (0,
                       /* Error displayed when no scanners to scan with */
                       _("No scanners available.  Please connect a scanner."));
            return;
        }

        /* See if we can use the already open device */
        if (have_handle)
        {
            if (current_device == job.device)
            {
                state = ScanState.GET_OPTION;
                return;
            }

            Sane.close (handle);
            debug ("sane_close ()");
            have_handle = false;
        }

        current_device = null;

        have_handle = false;
        options = new HashTable <string, int> (str_hash, str_equal);
        var status = Sane.open (job.device, out handle);
        debug ("sane_open (\"%s\") -> %s", job.device, Sane.status_to_string (status));

        if (status != Sane.Status.GOOD)
        {
            warning ("Unable to open device: %s", Sane.strstatus (status));
            fail_scan (status,
                       /* Error displayed when cannot connect to scanner */
                       _("Unable to connect to scanner"));
            return;
        }
        have_handle = true;

        current_device = job.device;
        state = ScanState.GET_OPTION;
    }

    private void set_adf (ScanJob job, Sane.OptionDescriptor option, Sane.Int index)
    {
        string[] adf_sources =
        {
            "Automatic Document Feeder",
            Sane.I18N ("Automatic Document Feeder"),
            "ADF",
            "Automatic Document Feeder(centrally aligned)", /* Seen in the proprietary brother3 driver */
            "Automatic Document Feeder(center aligned)", /* Seen in Brother's proprietary brscan5 driver */
            "Automatic Document Feeder(left aligned)", /* Seen in the proprietary brother3 driver */
            "ADF Simplex" /* Samsung unified driver. LP: # 892915 */
        };

        string[] adf_front_sources =
        {
            "ADF Front",
            Sane.I18N ("ADF Front")
        };

        string[] adf_back_sources =
        {
            "ADF Back",
            Sane.I18N ("ADF Back")
        };

        string[] adf_duplex_sources =
        {
            "ADF Duplex",
            "Duplex ADF", /* Brother DS-720, #157 */
            Sane.I18N ("ADF Duplex"),
            "ADF Duplex - Long-Edge Binding", /* Samsung unified driver. LP: # 892915 */
            "ADF Duplex - Short-Edge Binding",
            "Duplex", /* HP duplex scan support. LP: #1353599 */
            "Automatic Document Feeder(centrally aligned,Duplex)", /* Brother duplex scan support. LP: #1343773 */
            "Automatic Document Feeder(left aligned,Duplex)"
        };

        if (job.side == ScanSide.FRONT)
        {
            if (!set_constrained_string_option (handle, option, index, adf_front_sources, null))
                if (!set_constrained_string_option (handle, option, index, adf_sources, null))
                    warning ("Unable to set front ADF source, please file a bug");
        }
        else if (job.side == ScanSide.BACK)
        {
            if (!set_constrained_string_option (handle, option, index, adf_back_sources, null))
                if (!set_constrained_string_option (handle, option, index, adf_sources, null))
                    warning ("Unable to set back ADF source, please file a bug");
        }
        else if (job.side == ScanSide.BOTH)
        {
            if (!set_constrained_string_option (handle, option, index, adf_duplex_sources, null))
                if (!set_constrained_string_option (handle, option, index, adf_sources, null))
                    warning ("Unable to set duplex ADF source, please file a bug");
        }
    }

    private void do_get_option ()
    {
        var job = (ScanJob) job_queue.data;

        var option = Sane.get_option_descriptor (handle, option_index);
        debug ("sane_get_option_descriptor (%d)", (int) option_index);
        var index = option_index;
        option_index++;

        /* Options complete, apply settings */
        if (option == null)
        {
            /* Pick source */
            option = get_option_by_name (handle, Sane.NAME_SCAN_SOURCE, out index);
            if (option == null)
            {
                 option = get_option_by_name (handle, "doc-source", out index); /* Samsung unified driver. LP: #892915 */
            }
            if (option != null)
            {
                string[] flatbed_sources =
                {
                    "Auto",
                    Sane.I18N ("Auto"),
                    "Flatbed",
                    Sane.I18N ("Flatbed"),
                    "FlatBed",
                    "Normal",
                    Sane.I18N ("Normal"),
                    "Document Table" /* Epson scanners, eg. ET-3760 */
                };

                switch (job.type)
                {
                case ScanType.SINGLE:
                case ScanType.BATCH:
                    if (!set_default_option (handle, option, index))
                        if (!set_constrained_string_option (handle, option, index, flatbed_sources, null))
                        {
                            warning ("Unable to set single page source, trying to set ADF instead");
                            warning ("If Flatbed is existing and it is not set, please file a bug");
                            set_adf (job, option, index);
                        }
                    break;
                case ScanType.ADF:
                    set_adf (job, option, index);
                    break;
                }
            }

            /* Scan mode (before resolution as it tends to affect that */
            option = get_option_by_name (handle, Sane.NAME_SCAN_MODE, out index);
            if (option != null)
            {
                /* The names of scan modes often used in drivers, as taken from the sane-backends source */
                string[] color_scan_modes =
                {
                    Sane.VALUE_SCAN_MODE_COLOR,
                    "Color",
                    "24bit Color[Fast]", /* brother4 driver, Brother DCP-1622WE, #134 */
                    "24bit Color", /* Seen in the proprietary brother3 driver */
                    "24-bit Color", /* #161 Lexmark CX310dn */
                    "24 bit Color", /* brscanads2200ads2700w */
                    "Color - 16 Million Colors" /* Samsung unified driver. LP: 892915 */
                };
                string[] gray_scan_modes =
                {
                    Sane.VALUE_SCAN_MODE_GRAY,
                    "Gray",
                    "Grayscale",
                    Sane.I18N ("Grayscale"),
                    "8-bit Grayscale", /* #161 Lexmark CX310dn */
                    "True Gray", /* Seen in the proprietary brother3 driver */
                    "Grayscale - 256 Levels"  /* Samsung unified driver. LP: 892915 */
                };
                string[] lineart_scan_modes =
                {
                    Sane.VALUE_SCAN_MODE_LINEART,
                    "Lineart",
                    "LineArt",
                    Sane.I18N ("LineArt"),
                    "Black & White",
                    Sane.I18N ("Black & White"),
                    "Binary", /* Epson PM-A820 */
                    Sane.I18N ("Binary"),
                    "Thresholded",
                    Sane.VALUE_SCAN_MODE_GRAY,
                    "Gray",
                    "Grayscale",
                    Sane.I18N ("Grayscale"),
                    "True Gray", /* Seen in the proprietary brother3 driver */
                    "1-bit Black & White", /* #161 Lexmark CX310dn */
                    "Black and White - Line Art",  /* Samsung unified driver. LP: 892915 */
                    "Black and White - Halftone",
                    "Monochrome" /* Epson */
                };

                switch (job.scan_mode)
                {
                case ScanMode.COLOR:
                    if (!set_constrained_string_option (handle, option, index, color_scan_modes, null))
                        warning ("Unable to set Color mode, please file a bug");
                    break;
                case ScanMode.GRAY:
                    if (!set_constrained_string_option (handle, option, index, gray_scan_modes, null))
                        warning ("Unable to set Gray mode, please file a bug");
                    break;
                case ScanMode.LINEART:
                    if (!set_constrained_string_option (handle, option, index, lineart_scan_modes, null))
                        warning ("Unable to set Lineart mode, please file a bug");
                    break;
                default:
                    break;
                }
            }

            /* Duplex */
            option = get_option_by_name (handle, "duplex", out index);
            if (option == null) /* #161 Lexmark CX310dn Duplex */
                option = get_option_by_name (handle, "scan-both-sides", out index);
            if (option != null)
            {
                if (option.type == Sane.ValueType.BOOL)
                    set_bool_option (handle, option, index, job.side == ScanSide.BOTH, null);
            }

            /* Non-standard Epson GT-S50 ADF options */
            option = get_option_by_name (handle, "adf-mode", out index);

            /* Support Canon DR-C240 ADF_BOTH options */
            if (option == null)
                option = get_option_by_name (handle, "ScanMode", out index);
            if (option != null)
            {
                string[] adf_simplex_modes =
                {
                    "Simplex"
                };
                string[] adf_duplex_modes =
                {
                    "Duplex"
                };
                if (job.side == ScanSide.BOTH)
                    set_constrained_string_option (handle, option, index, adf_duplex_modes, null);
                else
                    set_constrained_string_option (handle, option, index, adf_simplex_modes, null);
            }
            option = get_option_by_name (handle, "adf-auto-scan", out index);
            if (option != null)
            {
                if (option.type == Sane.ValueType.BOOL)
                    set_bool_option (handle, option, index, true, null);
            }

            /* Multi-page options */
            option = get_option_by_name (handle, "batch-scan", out index);
            if (option != null)
            {
                if (option.type == Sane.ValueType.BOOL)
                    set_bool_option (handle, option, index, (job.type != ScanType.SINGLE) && (job.type != ScanType.BATCH), null);
            }

            /* Set resolution and bit depth */
            /* Epson may have separate resolution settings for x and y axes, which is preferable options to set */
            option = get_option_by_name (handle, Sane.NAME_SCAN_X_RESOLUTION, out index);
            if (option != null && (0 != (option.cap & Sane.Capability.SOFT_SELECT)))  // L4160 has non-selectable separate options
            {
                set_fixed_or_int_option (handle, option, index, job.dpi, out job.dpi);
                option = get_option_by_name (handle, Sane.NAME_SCAN_Y_RESOLUTION, out index);
            }
            else
                option = get_option_by_name (handle, Sane.NAME_SCAN_RESOLUTION, out index);
            if (option == null) /* #161 Lexmark CX310dn Duplex */
                option = get_option_by_name (handle, "scan-resolution", out index);
            if (option != null)
            {
                set_fixed_or_int_option (handle, option, index, job.dpi, out job.dpi);
                option = get_option_by_name (handle, Sane.NAME_BIT_DEPTH, out index);
                if (option != null)
                {
                    if (job.depth > 0)
                        set_int_option (handle, option, index, job.depth, null);
                }
            }

            /* Set scan area */
            option = get_option_by_name (handle, Sane.NAME_SCAN_BR_X, out index);
            if (option != null)
            {
                if (job.page_width > 0)
                    set_fixed_or_int_option (handle, option, index, convert_page_size (option, job.page_width, job.dpi), null);
                else
                    set_option_to_max (handle, option, index);
            }
            option = get_option_by_name (handle, Sane.NAME_SCAN_BR_Y, out index);
            if (option != null)
            {
                if (job.page_height > 0)
                    set_fixed_or_int_option (handle, option, index, convert_page_size (option, job.page_height, job.dpi), null);
                else
                    set_option_to_max (handle, option, index);
            }
            if (job.page_width == 0)
            {
                /* #90 Fix automatic mode for Epson scanners */
                option = get_option_by_name (handle, "scan-area", out index);
                if (option != null)
                    set_string_option (handle, option, index, "Maximum", null);

                /* #264 Enable automatic document size for Brother scanners */
                option = get_option_by_name (handle, "AutoDocumentSize", out index);
                if (option != null)
                    set_bool_option (handle, option, index, true, null);
            }
            /* Set page size */
            option = get_option_by_name (handle, Sane.NAME_PAGE_WIDTH, out index);
            if (option != null && job.page_width > 0.0)
                set_fixed_or_int_option (handle, option, index, convert_page_size (option, job.page_width, job.dpi), null);
            option = get_option_by_name (handle, Sane.NAME_PAGE_HEIGHT, out index);
            if (option != null && job.page_height > 0.0)
                set_fixed_or_int_option (handle, option, index, convert_page_size (option, job.page_height, job.dpi), null);

            var option_brightness = get_option_by_name (handle, Sane.NAME_BRIGHTNESS, out index);
            var option_contrast = get_option_by_name (handle, Sane.NAME_CONTRAST, out index);
            if (option_brightness != null && option_contrast != null)
            {
                // Brightness
                option = option_brightness;
                if (option.type == Sane.ValueType.FIXED)
                {
                    var brightness = scale_fixed (-100, 100, option, job.brightness);
                    set_fixed_option (handle, option, index, brightness, null);
                    debug ("Setting brightness to %f", brightness);
                }
                else if (option.type == Sane.ValueType.INT)
                {
                    var brightness = scale_int (-100, 100, option, job.brightness);
                    set_int_option (handle, option, index, brightness, null);
                    debug ("Setting brightness to %d", brightness);
                }
                else
                    warning ("Unable to set brightness, please file a bug");

                // Contrast
                option = option_contrast;
                if (option.type == Sane.ValueType.FIXED)
                {
                    var contrast = scale_fixed (-100, 100, option, job.contrast);
                    set_fixed_option (handle, option, index, contrast, null);
                    debug ("Setting contrast to %f", contrast);
                }
                else if (option.type == Sane.ValueType.INT)
                {
                    var contrast = scale_int (-100, 100, option, job.contrast);
                    set_int_option (handle, option, index, contrast, null);
                    debug ("Setting contrast to %d", contrast);
                }
                else
                    warning ("Unable to set contrast, please file a bug");
            }

            // Custom gamma is needed if brightness or contrast is set and the scanner does not support setting brightness or contrast directly
            var needs_custom_gamma = (job.brightness != 0 || job.contrast != 0) && (option_brightness == null || option_contrast == null);
            if (needs_custom_gamma) {
                option = get_option_by_name (handle, Sane.NAME_CUSTOM_GAMMA, out index);
                if (option != null)
                {
                    debug ("Setting custom gamma to %s", needs_custom_gamma ? "true" : "false");
                    if (option.type == Sane.ValueType.BOOL) {
                        set_bool_option (handle, option, index, needs_custom_gamma, null);

                        // Depends on printer model
                        const int gamma_table_size = 1024,
                            gamma_table_bit_depth = 16;

                        var brightness = job.brightness / 100.0;
                        var contrast = job.contrast / 100.0;
                        if (brightness < -1.0)
                            brightness = -1.0;
                        else if (brightness > 1.0)
                            brightness = 1.0;
                        if (contrast < -0.9999)
                            contrast = -0.9999;
                        else if (contrast > 0.9999)
                            contrast = 0.9999;

                        // Calculate a custom gamma table (stupid)
                        var gamma_table = new double [gamma_table_size];
                        for (var x = 1; x <= gamma_table_size; x++)
                        {
                            var max_val = Math.pow(2.0, gamma_table_bit_depth);

                            var y = (Math.tan(Math.PI / 2.0 * (contrast + 1.0) / 2.0) * (x - gamma_table_size / 2.0) / gamma_table_size + brightness + 0.5) * max_val;

                            if (y < 1.0)
                                y = 1.0;
                            else if (y > max_val)
                                y = max_val;

                            var yi = (int) (y - 1.0);

                            debug ("gamma_table[%d] = %d", x, yi);
                            gamma_table[x] = yi;
                        }

                        var gamma_vector_has_been_set = false;

                        // for grayscale
                        option = get_option_by_name (handle, Sane.NAME_GAMMA_VECTOR, out index);
                        if (option != null)
                        {
                            debug ("Setting gamma vector");
                            if (set_int_array_option (handle, option, index, gamma_table))
                                gamma_vector_has_been_set = true;
                            else
                                warning ("Unable to set gamma vector");
                        }

                        // for color
                        option = get_option_by_name (handle, Sane.NAME_GAMMA_VECTOR_R, out index);
                        if (option != null)
                        {
                            debug ("Setting gamma vector R");
                            if (set_int_array_option (handle, option, index, gamma_table))
                                gamma_vector_has_been_set = true;
                            else
                                warning ("Unable to set gamma vector R");
                        }
                        option = get_option_by_name (handle, Sane.NAME_GAMMA_VECTOR_G, out index);
                        if (option != null)
                        {
                            debug ("Setting gamma vector G");
                            if (set_int_array_option (handle, option, index, gamma_table))
                                gamma_vector_has_been_set = true;
                            else
                                warning ("Unable to set gamma vector G");
                        }
                        option = get_option_by_name (handle, Sane.NAME_GAMMA_VECTOR_B, out index);
                        if (option != null)
                        {
                            debug ("Setting gamma vector B");
                            if (set_int_array_option (handle, option, index, gamma_table))
                                gamma_vector_has_been_set = true;
                            else
                                warning ("Unable to set gamma vector B");
                        }

                        if (!gamma_vector_has_been_set)
                            warning ("Unable to set gamma vector!");
                    }
                }
            }

            /* Test scanner options (hoping will not effect other scanners...) */
            if (current_device == "test")
            {
                option = get_option_by_name (handle, "hand-scanner", out index);
                if (option != null)
                    set_bool_option (handle, option, index, false, null);
                option = get_option_by_name (handle, "three-pass", out index);
                if (option != null)
                    set_bool_option (handle, option, index, false, null);
                option = get_option_by_name (handle, "test-picture", out index);
                if (option != null)
                    set_string_option (handle, option, index, "Color pattern", null);
                option = get_option_by_name (handle, "read-delay", out index);
                if (option != null)
                    set_bool_option (handle, option, index, true, null);
                option = get_option_by_name (handle, "read-delay-duration", out index);
                if (option != null)
                    set_int_option (handle, option, index, 200000, null);
            }

            state = ScanState.START;
            return;
        }

        log_option (index, option);

        /* Ignore groups */
        if (option.type == Sane.ValueType.GROUP)
            return;

        /* Some options are unnamed (e.g. Option 0) */
        if (option.name == null)
            return;

        options.insert (option.name, (int) index);
    }

    private double convert_page_size (Sane.OptionDescriptor option, double size, double dpi)
    {
        if (option.unit == Sane.Unit.PIXEL)
            return dpi * size / 254.0;
        else if (option.unit == Sane.Unit.MM)
            return size / 10.0;
        else
        {
            warning ("Unable to set unsupported unit type");
            return 0.0f;
        }
    }

    private Sane.OptionDescriptor? get_option_by_name (Sane.Handle handle, string name, out int index)
    {
        index = options.lookup (name);
        if (index == 0)
            return null;

        var option_descriptor = Sane.get_option_descriptor (handle, index);
        /*
        The Sane.Capability.INACTIVE capability indicates that
        the option is not currently active (e.g., because it's meaningful
        only if another option is set to some other value).
        */
        if ((option_descriptor.cap & Sane.Capability.INACTIVE) != 0)
        {
            warning ("The option %s (%d) is inactive and can't be set, please file a bug", name, index);
            return null;
        }
        return option_descriptor;
    }

    private void do_complete_document ()
    {
        Sane.cancel (handle);
        debug ("sane_cancel ()");

        job_queue.remove_link (job_queue);

        state = ScanState.IDLE;

        /* Continue onto the next job */
        if (job_queue != null)
        {
            state = ScanState.OPEN;
            return;
        }

        /* Trigger timeout to close */
        // TODO

        notify_event (new NotifyDocumentDone ());
        set_scanning (false);
    }

    private void do_start ()
    {
        Sane.Status status;

        notify_event (new NotifyExpectPage ());

        status = Sane.start (handle);
        debug ("sane_start (page=%d, pass=%d) -> %s", page_number, pass_number, Sane.status_to_string (status));
        if (status == Sane.Status.GOOD)
            state = ScanState.GET_PARAMETERS;
        else if (status == Sane.Status.NO_DOCS)
        {
            do_complete_document ();
            if (page_number == 0)
                fail_scan (status,
                    /* Error displayed when no documents at the start of scanning */
                    _("Document feeder empty"));
        }
        else if (status == Sane.Status.NO_MEM)
        {
            fail_scan (status,
                /* Out of memory error message with help instruction.
                   Message written in Pango text markup language,
                   A carriage return makes a line break, <tt> tag makes a monospace font */
                _("Insufficient memory to perform scan.\n" +
                  "Try to decrease <tt>Resolution</tt> or <tt>Page Size</tt> in <tt>Preferences</tt> menu. " +
                  "For some scanners when scanning in high resolution, the scan size is restricted."));
        }
        else if (status == Sane.Status.DEVICE_BUSY)
        {
            /* If device is busy don't interrupt, but keep waiting for scanner */
        }
        else
        {
            warning ("Unable to start device: %s", Sane.strstatus (status));
            fail_scan (status,
                       /* Error display when unable to start scan */
                       _("Unable to start scan"));
        }
    }

    private void do_get_parameters ()
    {
        var status = Sane.get_parameters (handle, out parameters);
        debug ("sane_get_parameters () -> %s", Sane.status_to_string (status));
        if (status != Sane.Status.GOOD)
        {
            warning ("Unable to get device parameters: %s", Sane.strstatus (status));
            fail_scan (status,
                       /* Error displayed when communication with scanner broken */
                       _("Error communicating with scanner"));
            return;
        }

        var job = (ScanJob) job_queue.data;

        debug ("Parameters: format=%s last_frame=%s bytes_per_line=%d pixels_per_line=%d lines=%d depth=%d",
               Sane.frame_to_string (parameters.format),
               parameters.last_frame ? "SANE_TRUE" : "SANE_FALSE",
               parameters.bytes_per_line,
               parameters.pixels_per_line,
               parameters.lines,
               parameters.depth);

        var info = new ScanPageInfo ();
        info.width = parameters.pixels_per_line;
        info.height = parameters.lines;
        info.depth = parameters.depth;
        /* Reduce bit depth if requested lower than received */
        // FIXME: This a hack and only works on 8 bit gray to 2 bit gray
        if (parameters.depth == 8 && parameters.format == Sane.Frame.GRAY && job.depth == 2 && job.scan_mode == ScanMode.GRAY)
            info.depth = job.depth;
        info.n_channels = parameters.format == Sane.Frame.GRAY ? 1 : 3;
        info.dpi = job.dpi; // FIXME: This is the requested DPI, not the actual DPI
        info.device = current_device;

        if (page_number != notified_page)
        {
            notify_event (new NotifyGotPageInfo (job.id, info));
            notified_page = page_number;
        }

        /* Prepare for read */
        var buffer_size = parameters.bytes_per_line + 1; /* Use +1 so buffer is not resized if driver returns one line per read */
        buffer = new uchar[buffer_size];
        n_used = 0;
        line_count = 0;
        pass_number = 0;
        state = ScanState.READ;
    }

    private void do_complete_page ()
    {
        var job = (ScanJob) job_queue.data;

        notify_event (new NotifyPageDone (job.id));

        /* If multi-pass then scan another page */
        if (!parameters.last_frame)
        {
            pass_number++;
            state = ScanState.START;
            return;
        }

        /* Go back for another page */
        if (job.type != ScanType.SINGLE)
        {
            if (job.type == ScanType.BATCH)
                Thread.usleep (job.page_delay * 1000);

            page_number++;
            pass_number = 0;
            state = ScanState.START;
            return;
        }

        do_complete_document ();
    }

    private void do_read ()
    {
        var job = (ScanJob) job_queue.data;

        /* Read as many bytes as we expect */
        var n_to_read = buffer.length - n_used;

        Sane.Int n_read;
        var b = (uchar *) buffer;
        var status = Sane.read (handle, (uint8[]) (b + n_used), (Sane.Int) n_to_read, out n_read);
        debug ("sane_read (%d) -> (%s, %d)", n_to_read, Sane.status_to_string (status), (int) n_read);

        /* Completed read */
        if (status == Sane.Status.EOF)
        {
            if (parameters.lines > 0 && line_count != parameters.lines)
                warning ("Scan completed with %d lines, expected %d lines", line_count, parameters.lines);
            if (n_used > 0)
                warning ("Scan complete with %d bytes of unused data", n_used);
            do_complete_page ();
            return;
        }

        /* Some ADF scanners only return NO_DOCS after a read */
        if (status == Sane.Status.NO_DOCS)
        {
            do_complete_document ();
            if (page_number == 0)
                fail_scan (status,
                    /* Error displayed when no documents at the start of scanning */
                    _("Document feeder empty"));
            return;
        }

        /* Communication error */
        if (status != Sane.Status.GOOD)
        {
            warning ("Unable to read frame from device: %s", Sane.strstatus (status));
            fail_scan (status,
                       /* Error displayed when communication with scanner broken */
                       _("Error communicating with scanner"));
            return;
        }

        bool full_read = false;
        if (n_used == 0 && n_read == buffer.length)
            full_read = true;
        n_used += (int) n_read;

        /* Feed out lines */
        if (n_used >= parameters.bytes_per_line)
        {
            var line = new ScanLine ();
            switch (parameters.format)
            {
            case Sane.Frame.GRAY:
                line.channel = 0;
                break;
            case Sane.Frame.RGB:
                line.channel = -1;
                break;
            case Sane.Frame.RED:
                line.channel = 0;
                break;
            case Sane.Frame.GREEN:
                line.channel = 1;
                break;
            case Sane.Frame.BLUE:
                line.channel = 2;
                break;
            }
            line.width = parameters.pixels_per_line;
            line.depth = parameters.depth;
            line.data = (owned) buffer;
            line.data_length = parameters.bytes_per_line;
            line.number = line_count;
            line.n_lines = n_used / line.data_length;

            line_count += line.n_lines;

            /* Increase buffer size if did full read */
            var buffer_size = line.data.length;
            if (full_read)
                buffer_size += parameters.bytes_per_line;

            buffer = new uchar[buffer_size];
            var n_remaining = n_used - (line.n_lines * line.data_length);
            n_used = 0;
            for (var i = 0; i < n_remaining; i++)
            {
                buffer[i] = line.data[i + (line.n_lines * line.data_length)];
                n_used++;
            }

            /* Reduce bit depth if requested lower than received */
            // FIXME: This a hack and only works on 8 bit gray to 2 bit gray
            if (parameters.depth == 8 && parameters.format == Sane.Frame.GRAY &&
                job.depth == 2 && job.scan_mode == ScanMode.GRAY)
            {
                uchar block = 0;
                var write_offset = 0;
                var block_shift = 6;
                for (var i = 0; i < line.n_lines; i++)
                {
                    var offset = i * line.data_length;
                    for (var x = 0; x < line.width; x++)
                    {
                         var p = line.data[offset + x];

                         uchar sample;
                         if (p >= 192)
                             sample = 3;
                         else if (p >= 128)
                             sample = 2;
                         else if (p >= 64)
                             sample = 1;
                         else
                             sample = 0;

                         block |= sample << block_shift;
                         if (block_shift == 0)
                         {
                             line.data[write_offset] = block;
                             write_offset++;
                             block = 0;
                             block_shift = 6;
                         }
                         else
                             block_shift -= 2;
                    }

                    /* Finish each line on a byte boundary */
                    if (block_shift != 6)
                    {
                        line.data[write_offset] = block;
                        write_offset++;
                        block = 0;
                        block_shift = 6;
                    }
                }

                line.data_length = (line.width * 2 + 7) / 8;
            }

            notify_event (new NotifyGotLine (job.id, line));
        }
    }

    private void* scan_thread ()
    {
        state = ScanState.IDLE;

        Sane.Int version_code;
        var status = Sane.init (out version_code, authorization_cb);
        debug ("sane_init () -> %s", Sane.status_to_string (status));
        if (status != Sane.Status.GOOD)
        {
            warning ("Unable to initialize SANE backend: %s", Sane.strstatus(status));
            return null;
        }
        debug ("SANE version %d.%d.%d",
               Sane.VERSION_MAJOR(version_code),
               Sane.VERSION_MINOR(version_code),
               Sane.VERSION_BUILD(version_code));

        /* Scan for devices on first start */
        redetect ();

        while (handle_requests ())
        {
            switch (state)
            {
            case ScanState.IDLE:
                 if (job_queue != null)
                 {
                     set_scanning (true);
                     state = ScanState.OPEN;
                 }
                 break;
            case ScanState.REDETECT:
                do_redetect ();
                break;
            case ScanState.OPEN:
                do_open ();
                break;
            case ScanState.GET_OPTION:
                do_get_option ();
                break;
            case ScanState.START:
                do_start ();
                break;
            case ScanState.GET_PARAMETERS:
                do_get_parameters ();
                break;
            case ScanState.READ:
                do_read ();
                break;
            }
        }

        return null;
    }

    public void start ()
    {
        try
        {
            thread = new Thread<void*>.try ("scan-thread", scan_thread);
        }
        catch (Error e)
        {
            critical ("Unable to create thread: %s", e.message);
        }
    }

    public void redetect ()
    {
        if (need_redetect)
            return;
        need_redetect = true;

        debug ("Requesting redetection of scan devices");

        request_queue.push (new RequestRedetect ());
    }

    public bool is_scanning ()
    {
        return scanning;
    }

    private string get_scan_mode_string (ScanMode mode)
    {
        switch (mode)
        {
        case ScanMode.DEFAULT:
            return "ScanMode.DEFAULT";
        case ScanMode.COLOR:
            return "ScanMode.COLOR";
        case ScanMode.GRAY:
            return "ScanMode.GRAY";
        case ScanMode.LINEART:
            return "ScanMode.LINEART";
        default:
            return "%d".printf (mode);
        }
    }

    public static string type_to_string (ScanType type)
    {
        switch (type)
        {
        case ScanType.SINGLE:
            return "single";
        case ScanType.BATCH:
            return "batch";
        case ScanType.ADF:
            return "adf";
        default:
            return "%d".printf (type);
        }
    }

    public static ScanType type_from_string (string type)
    {
        switch (type)
        {
        case "single":
            return ScanType.SINGLE;
        case "batch":
            return ScanType.BATCH;
        case "adf":
            return ScanType.ADF;
        default:
            warning ("Unknown ScanType: %s. Please report this error.", type);
            return ScanType.SINGLE;
        }
    }

    public static string side_to_string (ScanSide side)
    {
        switch (side)
        {
        case ScanSide.FRONT:
            return "front";
        case ScanSide.BACK:
            return "back";
        case ScanSide.BOTH:
            return "both";
        default:
            return "%d".printf (side);
        }
    }

    public static ScanSide side_from_string (string side)
    {
        switch (side)
        {
        case "front":
            return ScanSide.FRONT;
        case "back":
            return ScanSide.BACK;
        case "both":
            return ScanSide.BOTH;
        default:
            warning ("Unknown ScanSide: %s. Please report this error.", side);
            return ScanSide.FRONT;
        }
    }

    public void scan (string? device, ScanOptions options)
    {
        debug ("Scanner.scan (\"%s\", dpi=%d, scan_mode=%s, depth=%d, type=%s, side=%s, paper_width=%d, paper_height=%d, brightness=%d, contrast=%d, delay=%dms)",
               device != null ? device : "(null)", options.dpi, get_scan_mode_string (options.scan_mode), options.depth,
               type_to_string (options.type), side_to_string (options.side),
               options.paper_width, options.paper_height,
               options.brightness, options.contrast, options.page_delay);
        var request = new RequestStartScan ();
        request.job = new ScanJob ();
        request.job.id = job_id++;
        request.job.device = device;
        request.job.dpi = options.dpi;
        request.job.scan_mode = options.scan_mode;
        request.job.depth = options.depth;
        request.job.type = options.type;
        request.job.side = options.side;
        request.job.page_width = options.paper_width;
        request.job.page_height = options.paper_height;
        request.job.brightness = options.brightness;
        request.job.contrast = options.contrast;
        request.job.page_delay = options.page_delay;
        request_queue.push (request);
    }

    public void cancel ()
    {
        first_job_id = job_id;
        request_queue.push (new RequestCancel ());
    }

    public void free ()
    {
        debug ("Stopping scan thread");

        request_queue.push (new RequestQuit ());

        if (thread != null)
        {
            thread.join ();
            thread = null;
        }

        Sane.exit ();
        debug ("sane_exit ()");
    }
}
